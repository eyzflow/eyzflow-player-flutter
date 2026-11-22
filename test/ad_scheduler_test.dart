import 'dart:async';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/ad_scheduler.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the scheduler asks for.
final class _Driver implements AdDriver {
  final List<String> calls = <String>[];
  final List<Duration> progress = <Duration>[];

  int count(String call) => calls.where((String c) => c == call).length;

  @override
  void requestAds() => calls.add('request');
  @override
  void startAds() => calls.add('start');
  @override
  void discardAds() => calls.add('discard');
  @override
  void contentComplete() => calls.add('contentComplete');
  @override
  void contentProgress(Duration position) => progress.add(position);
  @override
  void pauseContent() => calls.add('pause');
  @override
  void resumeContent() => calls.add('resume');
}

const Duration _vastCues = Duration.zero;
const List<Duration> _vast = <Duration>[];
const List<Duration> _vmapPreMidPost = <Duration>[
  _vastCues,
  Duration(seconds: 15),
  Duration(seconds: -1),
];
const List<Duration> _vmapMidOnly = <Duration>[Duration(seconds: 15)];

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

/// Plays the content from [from] to [to] in 0.5 s steps, as the native
/// player reports it.
void _play(AdBreakScheduler ads, num from, num to) {
  for (num t = from; t <= to; t += 0.5) {
    ads.contentPosition(_s(t));
  }
}

final class _Harness {
  _Harness({List<int> markers = const <int>[], PlayerAds? ads, this.airPlay})
    : ads = ads ?? PlayerAds(adTagUrl: 'https://ads.example.com/vast') {
    this.ads.loadMarkers(
      () async => <AdBreak>[
        for (final int s in markers)
          AdBreak(
            id: 'eyz-ad-$s',
            start: Duration(seconds: s),
          ),
      ],
    );
    scheduler = AdBreakScheduler(
      ads: this.ads,
      driver: driver,
      onBreakStarted: () => events.add('break started'),
      onBreakEnded: () => events.add('break ended'),
      suppressed: () => airPlay ?? false,
    );
  }

  final PlayerAds ads;
  final _Driver driver = _Driver();
  final List<String> events = <String>[];
  bool? airPlay;
  late final AdBreakScheduler scheduler;

  /// Starts the content: the pre-roll (if any) first. Returns whether the
  /// content may play yet.
  bool Function() start(FakeAsync async) {
    var released = false;
    unawaited(scheduler.beforeContent().then((_) => released = true));
    async.flushMicrotasks();
    return () => released;
  }
}

void main() {
  group('stream without markers: the tag decides', () {
    test('a VAST pre-roll plays before the content', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        final bool Function() released = h.start(async);
        expect(h.driver.calls, <String>['request']);
        expect(h.scheduler.inBreak, isTrue);
        expect(h.scheduler.containerNeeded, isTrue);
        expect(released(), isFalse);

        h.scheduler.adsLoaded(_vast);
        h.scheduler.contentPauseRequested();
        expect(h.scheduler.adPlaying, isTrue);
        async.elapse(const Duration(seconds: 30));
        expect(released(), isFalse, reason: 'the ad is still playing');

        h.scheduler.contentResumeRequested();
        async.flushMicrotasks();
        expect(released(), isTrue);
        expect(h.driver.calls, <String>['request', 'start', 'discard']);
        expect(h.scheduler.containerNeeded, isFalse);
        expect(h.events, <String>['break started', 'break ended']);
      });
    });

    test('the driver has the request before the layer is told', () {
      fakeAsync((FakeAsync async) {
        // The ad layer rebuilds on the notification and mounts the display
        // container the driver made for the request: it must exist by then.
        final _Harness h = _Harness();
        final List<int> requestsSeen = <int>[];
        h.scheduler.addListener(
          () => requestsSeen.add(h.driver.count('request')),
        );
        h.start(async);
        expect(requestsSeen.first, 1);
      });
    });

    test('a VMAP keeps its own schedule: mid-roll and post-roll', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        final bool Function() released = h.start(async);
        h.scheduler.adsLoaded(_vmapPreMidPost);
        h.scheduler.contentPauseRequested();
        h.scheduler.contentResumeRequested();
        async.flushMicrotasks();
        expect(released(), isTrue);
        expect(h.driver.count('discard'), 0, reason: 'more breaks to come');
        expect(h.scheduler.containerNeeded, isTrue);
        expect(h.scheduler.inBreak, isFalse);

        // IMA follows the content and pauses it at its own cue point.
        _play(h.scheduler, 0, 15);
        expect(h.driver.progress.last, _s(15));
        h.scheduler.contentPauseRequested();
        expect(h.driver.calls.last, 'pause');
        h.scheduler.contentResumeRequested();
        expect(h.driver.calls.last, 'resume');

        var finished = false;
        unawaited(h.scheduler.contentCompleted().then((_) => finished = true));
        async.flushMicrotasks();
        expect(h.driver.calls.last, 'contentComplete');
        h.scheduler.contentPauseRequested();
        h.scheduler.allAdsCompleted();
        // The finished content is neither paused nor played again.
        expect(h.driver.count('pause'), 1);
        expect(h.driver.count('resume'), 1);
        async.flushMicrotasks();
        expect(finished, isTrue);
        expect(h.driver.count('discard'), 1);
      });
    });

    test('a VMAP without a pre-roll lets the content start at once', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        final bool Function() released = h.start(async);
        h.scheduler.adsLoaded(_vmapMidOnly);
        async.flushMicrotasks();
        expect(released(), isTrue);
        expect(h.driver.calls, <String>['request', 'start']);
        expect(h.scheduler.containerNeeded, isTrue);
      });
    });

    test('an empty or failed tag starts the content, no error', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        final bool Function() released = h.start(async);
        h.scheduler.adsFailed();
        async.flushMicrotasks();
        expect(released(), isTrue);
        expect(h.scheduler.containerNeeded, isFalse);
        expect(h.events, <String>['break started', 'break ended']);
      });
    });

    test('a tag that never answers starts the content after the guard', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        final bool Function() released = h.start(async);
        async.elapse(const Duration(seconds: 11));
        expect(released(), isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(released(), isTrue);
        expect(h.driver.calls, <String>['request', 'discard']);
        // A late answer is dropped.
        h.scheduler.adsLoaded(_vast);
        expect(h.driver.count('start'), 0);
      });
    });

    test('the post-roll is skipped without one', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness();
        h.start(async);
        h.scheduler.adsLoaded(_vmapMidOnly);
        var finished = false;
        unawaited(h.scheduler.contentCompleted().then((_) => finished = true));
        async.flushMicrotasks();
        expect(finished, isTrue);
        expect(h.driver.count('contentComplete'), 0);
      });
    });
  });

  group('stream with markers: the markers win', () {
    test('no pre-roll without a marker at the start; a mid-roll at 8 s', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8]);
        final bool Function() released = h.start(async);
        expect(released(), isTrue);
        expect(h.driver.calls, isEmpty);

        _play(h.scheduler, 0, 7.5);
        expect(h.driver.calls, isEmpty);
        h.scheduler.contentPosition(_s(8));
        expect(h.driver.calls, <String>['pause', 'request']);
        expect(h.scheduler.inBreak, isTrue);

        h.scheduler.adsLoaded(_vast);
        h.scheduler.contentPauseRequested();
        h.scheduler.contentResumeRequested();
        expect(h.driver.calls, <String>[
          'pause',
          'request',
          'start',
          'discard',
          'resume',
        ]);
        expect(h.events, <String>['break started', 'break ended']);

        // Rewinding and playing through 8 s again plays nothing.
        h.scheduler.contentPosition(_s(2));
        _play(h.scheduler, 2, 12);
        expect(h.driver.count('request'), 1);
      });
    });

    test('markers at 0 s and 8 s: a pre-roll, then a mid-roll', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[0, 8]);
        final bool Function() released = h.start(async);
        expect(h.driver.calls, <String>['request']);
        h.scheduler.adsLoaded(_vast);
        h.scheduler.contentPauseRequested();
        h.scheduler.contentResumeRequested();
        async.flushMicrotasks();
        expect(released(), isTrue);
        expect(h.driver.calls, <String>['request', 'start', 'discard']);

        _play(h.scheduler, 0, 8);
        expect(h.driver.count('request'), 2);
      });
    });

    test('a VMAP plays its pre-roll at each marker, nothing of its own', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8, 30]);
        h.start(async);
        _play(h.scheduler, 0, 8);
        h.scheduler.adsLoaded(_vmapPreMidPost);
        h.scheduler.contentPauseRequested();
        h.scheduler.contentResumeRequested();
        // Dropped after the break: its mid-roll at 15 s and post-roll never
        // play, and it is not told where the content is.
        expect(h.driver.calls.sublist(2), <String>[
          'start',
          'discard',
          'resume',
        ]);
        expect(h.scheduler.containerNeeded, isFalse);
        _play(h.scheduler, 8.5, 29.5);
        expect(h.driver.count('request'), 1);
        expect(h.driver.progress, isEmpty);
        h.scheduler.contentPosition(_s(30));
        expect(h.driver.count('request'), 2);

        var finished = false;
        unawaited(h.scheduler.contentCompleted().then((_) => finished = true));
        async.flushMicrotasks();
        expect(finished, isTrue);
        expect(h.driver.count('contentComplete'), 0);
      });
    });

    test('a mid-roll-only VMAP at a marker: no ad, no stall', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8]);
        h.start(async);
        _play(h.scheduler, 0, 8);
        h.scheduler.adsLoaded(_vmapMidOnly);
        expect(h.driver.calls, <String>[
          'pause',
          'request',
          'discard',
          'resume',
        ]);
        expect(h.scheduler.inBreak, isFalse);
      });
    });

    test('seeking past a marker plays no ad', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8]);
        h.start(async);
        _play(h.scheduler, 0, 4);
        h.scheduler.contentPosition(_s(20));
        _play(h.scheduler, 20.5, 25);
        expect(h.driver.calls, isEmpty);
      });
    });

    test('an empty tag at a mid-roll resumes the content', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8]);
        h.start(async);
        _play(h.scheduler, 0, 8);
        h.scheduler.adsFailed();
        expect(h.driver.calls, <String>[
          'pause',
          'request',
          'discard',
          'resume',
        ]);
      });
    });

    test('a mid-roll that never answers resumes after the guard', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[8]);
        h.start(async);
        _play(h.scheduler, 0, 8);
        async.elapse(const Duration(seconds: 12));
        expect(h.driver.calls.last, 'resume');
        expect(h.scheduler.inBreak, isFalse);
      });
    });

    test('no ads start while the video plays on AirPlay', () {
      fakeAsync((FakeAsync async) {
        final _Harness h = _Harness(markers: <int>[0, 8], airPlay: true);
        final bool Function() released = h.start(async);
        expect(released(), isTrue);
        _play(h.scheduler, 0, 10);
        expect(h.driver.calls, isEmpty);
      });
    });
  });

  test('a fresh player of the same impression plays no pre-roll again', () {
    fakeAsync((FakeAsync async) {
      final PlayerAds ads = PlayerAds(adTagUrl: 'https://ads.example.com/v');
      final _Harness first = _Harness(ads: ads, markers: <int>[0]);
      first.start(async);
      first.scheduler.adsFailed();
      first.scheduler.dispose();

      // Casting handed playback back to the phone.
      final _Harness second = _Harness(ads: ads);
      final bool Function() released = second.start(async);
      expect(released(), isTrue);
      expect(second.driver.calls, isEmpty);
    });
  });

  test('disposing during a break releases the content and ends the break', () {
    fakeAsync((FakeAsync async) {
      final _Harness h = _Harness();
      final bool Function() released = h.start(async);
      h.scheduler.dispose();
      async.flushMicrotasks();
      expect(released(), isTrue);
      expect(h.events, <String>['break started', 'break ended']);
      expect(h.driver.calls.last, 'discard');
    });
  });

  group('the config gates the ads', () {
    PlayerConfig config({required bool ads, String tag = ''}) =>
        PlayerConfig.fromJson(<String, Object?>{
          'features': <String, Object?>{'ads': ads},
          'ads': <String, Object?>{'adTagUrl': tag},
        });

    test('features.ads on and a tag: ads', () {
      final PlayerOptions options = PlayerOptions.fromConfig(
        config(ads: true, tag: ' https://ads.example.com/vast '),
      );
      expect(options.ads?.adTagUrl, 'https://ads.example.com/vast');
    });

    test('features.ads off, or no tag: no ads at all', () {
      expect(
        PlayerOptions.fromConfig(
          config(ads: false, tag: 'https://ads.example.com/vast'),
        ).ads,
        isNull,
      );
      expect(PlayerOptions.fromConfig(config(ads: true)).ads, isNull);
      expect(
        PlayerOptions.fromConfig(config(ads: true, tag: '  ')).ads,
        isNull,
      );
      expect(const PlayerOptions().ads, isNull);
    });
  });
}
