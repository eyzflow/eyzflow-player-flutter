import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _target = UsageTarget(
  storefrontId: 'sf',
  authorization: 'Bearer viewer',
  offerId: '0b6c7c55-2a8e-4b1f-9d6e-1c2f3a4b5c6d',
  catalogueId: '6f1e2d3c-4b5a-4968-8776-655443322110',
);

final class _Harness {
  _Harness([
    List<UsageSendResult> results = const [],
    UsageTarget target = _target,
  ]) : _results = [...results] {
    reporter = UsageReporter(
      target: target,
      playedMs: () => playedMs,
      send: (_, body) async {
        sent.add(body);
        return _results.isEmpty ? UsageSendResult.ok : _results.removeAt(0);
      },
      sessionId: 'sess-0001',
    );
  }

  final List<UsageSendResult> _results;
  final sent = <Map<String, Object?>>[];
  var playedMs = 0;
  late final UsageReporter reporter;

  List<Object?> get seconds => [for (final b in sent) b['watched_seconds']];
}

void main() {
  group('UsageReporter', () {
    test(
      'reports the whole seconds played since the last report, with one session id',
      () async {
        final h = _Harness();
        h.playedMs = 30400;
        await h.reporter.report();
        h.playedMs += 29800;
        await h.reporter.report();
        expect(h.seconds, [30, 30]);
        expect(h.sent.first, {
          'offer_id': _target.offerId,
          'catalogue_id': _target.catalogueId,
          'session_id': 'sess-0001',
          'watched_seconds': 30,
          'is_trailer': false,
        });
      },
    );

    test('sends nothing for less than a second', () async {
      final h = _Harness();
      h.playedMs = 900;
      await h.reporter.report();
      expect(h.sent, isEmpty);
    });

    test(
      'sends at most 120 s at once and the rest with the next report',
      () async {
        final h = _Harness();
        h.playedMs = 200000;
        await h.reporter.report();
        await h.reporter.report();
        expect(h.seconds, [120, 80]);
      },
    );

    test(
      'sends seconds again after a failed report, but not after a refused one',
      () async {
        final h = _Harness([
          UsageSendResult.retry,
          UsageSendResult.ok,
          UsageSendResult.drop,
        ]);
        h.playedMs = 10000;
        await h.reporter.report();
        h.playedMs += 5000;
        await h.reporter.report();
        h.playedMs += 7000;
        await h.reporter.report();
        h.playedMs += 3000;
        await h.reporter.report();
        expect(h.seconds, [10, 15, 7, 3]);
      },
    );

    test('reports every 30 s, and once more when stopped', () {
      fakeAsync((async) {
        final h = _Harness();
        h.reporter.start();
        h.playedMs = 30000;
        async.elapse(const Duration(seconds: 30));
        h.playedMs += 12000;
        h.reporter.stop();
        h.reporter.stop();
        async.flushMicrotasks();
        h.playedMs += 8000;
        h.reporter.report();
        async.elapse(const Duration(seconds: 60));
        expect(h.seconds, [30, 12]);
        expect(async.periodicTimerCount, 0);
      });
    });

    test('leaves out a catalogue id that is not a UUID', () async {
      final h = _Harness(
        const [],
        const UsageTarget(
          storefrontId: 'sf',
          authorization: 'Bearer viewer',
          offerId: 'offer-1',
          catalogueId: 'film-42',
        ),
      );
      h.playedMs = 5000;
      await h.reporter.report();
      expect(h.sent.first.containsKey('catalogue_id'), isFalse);
    });

    test(
      "posts to playback-events with the viewer's authorization; 404 is dropped, 500 retried",
      () async {
        var status = 201;
        final requests = <http.Request>[];
        final sender = HttpUsageSender(
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('', status);
          }),
        );
        expect(
          await sender(_target, {'watched_seconds': 30}),
          UsageSendResult.ok,
        );
        status = 404;
        expect(
          await sender(_target, {'watched_seconds': 30}),
          UsageSendResult.drop,
        );
        status = 500;
        expect(
          await sender(_target, {'watched_seconds': 30}),
          UsageSendResult.retry,
        );
        expect(requests.first.method, 'POST');
        expect(
          requests.first.url.path,
          '/v1/content/storefront/sf/playback-events',
        );
        expect(requests.first.headers['Authorization'], 'Bearer viewer');
        expect(jsonDecode(requests.first.body), {'watched_seconds': 30});
      },
    );
  });

  group('PlaybackCoordinator royalty usage', () {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/playback-sessions')) {
        return http.Response(
          jsonEncode({'id': 'ps_1', 'heartbeat_interval_seconds': 600}),
          201,
        );
      }
      return http.Response('', 204);
    });

    PlaybackCoordinator coordinator(
      PlaybackCoordinatorConfig config,
      int Function() clock,
      List<Map<String, Object?>> sent,
    ) => PlaybackCoordinator(
      config: config,
      licenseClient: PlayerLicenseClient(client: client),
      sessionClient: PlaybackSessionClient(client: client),
      beatSender: (_) async => true,
      usageSender: (_, body) async {
        sent.add(body);
        return UsageSendResult.ok;
      },
      deviceIdStore: MemoryDeviceIdStore('device-1'),
      now: clock,
    );

    test(
      "reports the film's played time without a player key, on pause and on close; ads, seeks and stalls add nothing",
      () {
        fakeAsync((async) {
          var now = 0;
          final sent = <Map<String, Object?>>[];
          final c = coordinator(
            const PlaybackCoordinatorConfig(
              streamId: 'stream-1',
              isProtected: true,
              drmAuthorization: 'Bearer viewer',
              storefrontId: 'sf',
              platform: PlayerPlatform.android,
              offerId: 'offer-1',
            ),
            () => now,
            sent,
          )..start();
          async.flushMicrotasks();
          Duration s(int seconds) => Duration(seconds: seconds);

          c.onPlaybackEvent(
            PlaybackStarted(sourceId: 'stream-1', position: Duration.zero),
          );
          now += 20000;
          c.onPlaybackEvent(
            PlaybackAdBreakStarted(sourceId: 'stream-1', position: s(20)),
          );
          now += 30000; // a 30 s ad
          c.onPlaybackEvent(
            PlaybackAdBreakEnded(sourceId: 'stream-1', position: s(20)),
          );
          c.onPlaybackEvent(
            PlaybackSeeked(
              sourceId: 'stream-1',
              from: s(20),
              position: s(1800),
            ),
          );
          c.onPlaybackEvent(
            PlaybackBufferingStarted(sourceId: 'stream-1', position: s(1800)),
          );
          now += 2000;
          c.onPlaybackEvent(
            PlaybackBufferingEnded(sourceId: 'stream-1', position: s(1800)),
          );
          now += 5000;
          c.onPlaybackEvent(
            PlaybackPaused(sourceId: 'stream-1', position: s(1805)),
          );
          async.flushMicrotasks();
          now += 60000; // paused
          c.onPlaybackEvent(
            PlaybackResumed(sourceId: 'stream-1', position: s(1805)),
          );
          now += 7000;
          c.close();
          async.flushMicrotasks();

          expect([for (final b in sent) b['watched_seconds']], [25, 7]);
          expect({for (final b in sent) b['session_id']}, hasLength(1));
          expect(sent.every((b) => b['offer_id'] == 'offer-1'), isTrue);
        });
      },
    );

    test('reports nothing without an offer id or a viewer', () {
      fakeAsync((async) {
        var now = 0;
        final sent = <Map<String, Object?>>[];
        for (final config in const [
          PlaybackCoordinatorConfig(
            streamId: 's',
            isProtected: true,
            drmAuthorization: 'Bearer viewer',
            storefrontId: 'sf',
            platform: PlayerPlatform.android,
          ),
          PlaybackCoordinatorConfig(
            streamId: 's',
            isProtected: false,
            storefrontId: 'sf',
            platform: PlayerPlatform.android,
            offerId: 'offer-1',
          ),
        ]) {
          final c = coordinator(config, () => now, sent)..start();
          async.flushMicrotasks();
          c.onPlaybackEvent(
            PlaybackStarted(sourceId: 's', position: Duration.zero),
          );
          now += 30000;
          c.close();
          async.flushMicrotasks();
        }
        expect(sent, isEmpty);
      });
    });
  });
}
