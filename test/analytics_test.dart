import 'package:eyzflow_player/src/core/analytics/beat.dart';
import 'package:eyzflow_player/src/core/analytics/collector.dart';
import 'package:eyzflow_player/src/core/analytics/transport.dart';
import 'package:eyzflow_player/src/core/api.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

void main() {
  group('BeatCollector', () {
    late int now;
    late BeatCollector collector;
    var milestones = 0;

    setUp(() {
      now = 0;
      milestones = 0;
      collector = BeatCollector(now: () => now)
        ..onMilestone = () => milestones += 1;
    });

    test('times startup to ready and to the first frame', () {
      now = 400;
      collector.ready(duration: _s(3600));
      now = 1500;
      collector.playing(position: Duration.zero);

      final m = collector.metrics();
      expect(m.playerStartupMs, 400);
      expect(m.videoStartupMs, 1500);
      expect(m.durationS, 3600);
      expect(milestones, 1);
    });

    test('adds time to the state being left, the open one included', () {
      collector.playing(position: Duration.zero);
      now = 10000;
      collector.paused(position: _s(10));
      now = 15000;
      collector.playing(position: _s(10));
      now = 17000;
      collector.bufferingStarted();
      now = 20000;

      final m = collector.metrics();
      expect(m.playedMs, 12000);
      expect(m.pausedMs, 5000);
      expect(m.rebufferMs, 3000);
      expect(m.rebufferCount, 1);
    });

    test('buffering before the first frame is startup, not a stall', () {
      collector.bufferingStarted();
      now = 2000;
      collector.bufferingEnded();
      collector.playing(position: Duration.zero);

      expect(collector.metrics().rebufferCount, 0);
    });

    test('ending a stall returns to playing or paused', () {
      collector.playing(position: Duration.zero);
      collector.bufferingStarted();
      collector.bufferingEnded(isPlaying: false);
      expect(collector.state, BeatState.paused);
    });

    test(
      'counts seeks after the first frame; the seek loading is no stall',
      () {
        collector.seeked(to: _s(30));
        collector.playing(position: _s(30));
        now = 5000;
        collector.seeked(to: _s(600));
        now = 5500;
        collector.bufferingStarted(position: _s(600));
        now = 7000;
        collector.bufferingEnded(position: _s(600));
        now = 60000;
        collector.bufferingStarted(position: _s(653));

        final m = collector.metrics();
        expect(m.seekCount, 1);
        expect(m.rebufferCount, 1);
        // Played up to the buffering after the seek, and again after it.
        expect(m.playedMs, 5500 + 53000);
      },
    );

    test('estimates the position while playing, up to the duration', () {
      collector.ready(duration: _s(100));
      collector.playing(position: _s(10));
      now = 30000;
      expect(collector.metrics().maxPositionS, 40);
      now = 200000;
      expect(collector.metrics().maxPositionS, 100);
    });

    test('keeps the furthest position across a seek back', () {
      collector.playing(position: _s(10));
      now = 50000;
      collector.seeked(to: _s(5));
      expect(collector.metrics().maxPositionS, 60);
    });

    test('keeps at most 20 errors, sends each once, returns unsent ones', () {
      collector.playing(position: Duration.zero);
      for (var i = 0; i < 25; i++) {
        collector.error(code: 'E$i', message: 'x' * 400, fatal: false);
      }
      final errors = collector.takeErrors();
      expect(errors, hasLength(20));
      expect(errors.first.n, 0);
      expect(errors.first.message, hasLength(300));
      expect(collector.takeErrors(), isEmpty);
      expect(milestones, 1 + 25);

      collector.returnErrors(errors.take(2).toList());
      expect(collector.takeErrors().map((e) => e.code), ['E0', 'E1']);
    });

    test('a fatal error ends the impression', () {
      collector.playing(position: Duration.zero);
      now = 4000;
      collector.error(code: 'PLAYBACK_FAILED');
      now = 9000;
      collector.playing();

      expect(collector.state, BeatState.error);
      expect(collector.metrics().playedMs, 4000);
    });

    test('completion stops the clock', () {
      collector.playing(position: Duration.zero);
      now = 3000;
      collector.completed(position: _s(3));
      now = 9000;
      expect(collector.state, BeatState.ended);
      expect(collector.metrics().playedMs, 3000);
    });
  });

  group('BeatTransport', () {
    test('beats on the first frame, every interval, and a final one', () {
      fakeAsync((async) {
        final beats = <Beat>[];
        final collector = BeatCollector(now: () => 0);
        final transport = BeatTransport(
          collector: collector,
          token: () => 'plk1.a.b',
          streamId: 'stream-1',
          interval: const Duration(seconds: 60),
          send: (beat) async {
            beats.add(beat);
            return true;
          },
          drm: 'widevine',
          platform: PlayerPlatform.androidTv,
          impressionId: '00000000-0000-4000-8000-000000000000',
          wallClock: () => DateTime.fromMillisecondsSinceEpoch(1000),
        )..start();

        collector.playing(position: Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 120));
        transport.stop();
        async.flushMicrotasks();

        expect(beats.map((b) => b.seq), [1, 2, 3, 4]);
        expect(beats.map((b) => b.isFinal), [false, false, false, true]);
        final json = beats.last.toJson();
        expect(json['token'], 'plk1.a.b');
        expect(json['sid'], '00000000-0000-4000-8000-000000000000');
        expect(json['started_at'], 1000);
        expect(json['stream_id'], 'stream-1');
        expect(json['drm'], 'widevine');
        expect(json['platform'], 'androidtv');
        expect(json['autoplay'], isTrue);
        expect(json['is_live'], isFalse);
        expect(json['player_version'], eyzflowPlayerVersion);
        expect(
          (json['m']! as Map).keys,
          containsAll(['played_ms', 'avg_bitrate']),
        );

        transport.stop();
        async.elapse(const Duration(seconds: 120));
        expect(beats, hasLength(4));
      });
    });

    test('sends nothing without a token', () {
      fakeAsync((async) {
        var sent = 0;
        BeatTransport(
          collector: BeatCollector(now: () => 0),
          token: () => null,
          streamId: 's',
          interval: const Duration(seconds: 10),
          send: (_) async {
            sent += 1;
            return true;
          },
        ).start();
        async.elapse(const Duration(seconds: 60));
        expect(sent, 0);
      });
    });

    test('puts back the errors of a beat that did not go', () {
      fakeAsync((async) {
        final collector = BeatCollector(now: () => 0);
        final sent = <List<String>>[];
        var online = false;
        final transport = BeatTransport(
          collector: collector,
          token: () => 't',
          streamId: 's',
          interval: const Duration(seconds: 60),
          send: (beat) async {
            sent.add([for (final e in beat.errors) e.code]);
            return online;
          },
        );

        collector.error(code: 'E1');
        async.flushMicrotasks();
        online = true;
        transport.beat();
        async.flushMicrotasks();

        expect(sent, [
          ['E1'],
          ['E1'],
        ]);
      });
    });

    test('beats at most every ten seconds', () {
      fakeAsync((async) {
        var sent = 0;
        BeatTransport(
          collector: BeatCollector(now: () => 0),
          token: () => 't',
          streamId: 's',
          interval: const Duration(seconds: 1),
          send: (_) async {
            sent += 1;
            return true;
          },
        ).start();
        async.elapse(const Duration(seconds: 30));
        expect(sent, 3);
      });
    });
  });
}
