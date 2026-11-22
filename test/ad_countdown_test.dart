import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/ad_countdown.dart';
import 'package:eyzflow_player/src/ads/ad_scheduler.dart';
import 'package:eyzflow_player/src/core/player_config.dart';
import 'package:eyzflow_player/src/player/player_options.dart';
import 'package:flutter_test/flutter_test.dart';

Duration _s(num seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

AdBreak _break(String id, num start) => AdBreak(id: id, start: _s(start));

final class _NoAds implements AdDriver {
  @override
  void requestAds() {}
  @override
  void startAds() {}
  @override
  void discardAds() {}
  @override
  void contentComplete() {}
  @override
  void contentProgress(Duration position) {}
  @override
  void pauseContent() {}
  @override
  void resumeContent() {}
}

void main() {
  group('countdownSeconds', () {
    test('counts down the last 5 s before a break, in whole seconds', () {
      final List<Duration> starts = <Duration>[_s(30)];
      expect(countdownSeconds(_s(24.9), starts), isNull);
      expect(countdownSeconds(_s(25), starts), 5);
      expect(countdownSeconds(_s(25.1), starts), 5);
      expect(countdownSeconds(_s(26), starts), 4);
      expect(countdownSeconds(_s(26.5), starts), 4);
      expect(countdownSeconds(_s(27.5), starts), 3);
      expect(countdownSeconds(_s(28.2), starts), 2);
      expect(countdownSeconds(_s(29), starts), 1);
      expect(countdownSeconds(_s(29.9), starts), 1);
      expect(countdownSeconds(_s(30), starts), isNull);
    });

    test('uses the nearest break ahead', () {
      expect(countdownSeconds(_s(57), <Duration>[_s(90), _s(30), _s(60)]), 3);
      expect(countdownSeconds(_s(10), const <Duration>[]), isNull);
    });

    test('a break seeked past has no countdown', () {
      expect(countdownSeconds(_s(40), <Duration>[_s(30)]), isNull);
    });
  });

  group('adCountdownFor', () {
    int? at({
      bool enabled = true,
      bool playing = true,
      bool inBreak = false,
      bool remote = false,
    }) => adCountdownFor(
      enabled: enabled,
      playing: playing,
      inBreak: inBreak,
      remote: remote,
      position: _s(27),
      starts: <Duration>[_s(30)],
    );

    test('shows while playing towards a break', () => expect(at(), 3));
    test('not when switched off', () => expect(at(enabled: false), isNull));
    test('not while paused or seeking', () {
      expect(at(playing: false), isNull);
    });
    test('not during an ad', () => expect(at(inBreak: true), isNull));
    test('not on AirPlay', () => expect(at(remote: true), isNull));
  });

  group('AdBreakSchedule.upcomingStarts', () {
    test('lists unplayed mid-roll markers, not the pre-roll', () {
      final AdBreakSchedule s = AdBreakSchedule(<AdBreak>[
        _break('pre', 0),
        _break('a', 30),
        _break('b', 60),
      ]);
      expect(s.upcomingStarts, <Duration>[_s(30), _s(60)]);
      s.due(_s(29.8), _s(30.1));
      expect(s.upcomingStarts, <Duration>[_s(60)]);
    });

    test('keeps a marker passed by seeking: it still plays later', () {
      final AdBreakSchedule s = AdBreakSchedule(<AdBreak>[_break('a', 30)]);
      expect(s.due(_s(27), _s(40)), isNull);
      expect(s.upcomingStarts, <Duration>[_s(30)]);
      expect(countdownSeconds(_s(26), s.upcomingStarts), 4);
    });
  });

  group('CuePointSchedule', () {
    test('keeps mid-roll cue points only, drops them once played through', () {
      final CuePointSchedule c = CuePointSchedule()
        ..set(<Duration>[Duration.zero, _s(15), const Duration(seconds: -1)]);
      expect(c.upcoming, <Duration>[_s(15)]);
      c.pass(_s(10), _s(12));
      expect(c.upcoming, <Duration>[_s(15)]);
      c.pass(_s(14.9), _s(15.1));
      expect(c.upcoming, isEmpty);
      // A rewind does not bring it back: IMA plays each break once.
      c.pass(_s(15.1), _s(5));
      expect(c.upcoming, isEmpty);
    });

    test('does not pass a cue point seeked over', () {
      final CuePointSchedule c = CuePointSchedule()..set(<Duration>[_s(15)]);
      c.pass(_s(10), _s(20));
      expect(c.upcoming, <Duration>[_s(15)]);
    });
  });

  group('AdBreakScheduler.upcomingMidrolls', () {
    test(
      'a VMAP on a stream without markers: its mid-roll cue points',
      () async {
        final AdBreakScheduler scheduler = AdBreakScheduler(
          ads: PlayerAds(adTagUrl: 'https://ads.example.com/vmap'),
          driver: _NoAds(),
        );
        addTearDown(scheduler.dispose);
        final Future<void> preroll = scheduler.beforeContent();
        await Future<void>.delayed(Duration.zero);
        scheduler.adsLoaded(<Duration>[
          Duration.zero,
          _s(15),
          const Duration(seconds: -1),
        ]);
        scheduler.contentPauseRequested();
        scheduler.contentResumeRequested();
        await preroll;
        expect(scheduler.upcomingMidrolls, <Duration>[_s(15)]);
        scheduler.contentPosition(_s(14.5));
        scheduler.contentPosition(_s(15));
        expect(scheduler.upcomingMidrolls, isEmpty);
      },
    );

    test('a stream with markers: the markers, not the tag', () async {
      final PlayerAds ads = PlayerAds(adTagUrl: 'https://ads.example.com/vast');
      await ads.loadMarkers(() async => <AdBreak>[_break('a', 30)]);
      final AdBreakScheduler scheduler = AdBreakScheduler(
        ads: ads,
        driver: _NoAds(),
      );
      addTearDown(scheduler.dispose);
      await scheduler.beforeContent();
      expect(scheduler.upcomingMidrolls, <Duration>[_s(30)]);
    });
  });

  group('adCountdownLabel', () {
    test('speaks the viewer\'s language', () {
      expect(adCountdownLabel(5, language: 'en'), 'Ad in 5');
      expect(adCountdownLabel(4, language: 'de'), 'Werbung in 4');
      expect(adCountdownLabel(3, language: 'fr'), 'Publicité dans 3');
      expect(adCountdownLabel(2, language: 'nl-BE'), 'Reclame over 2');
      expect(adCountdownLabel(1, language: 'es'), 'Ad in 1');
    });
  });

  group('features.adCountdown', () {
    test('missing (older configs) means on', () {
      final PlayerConfig config = PlayerConfig.fromJson(<String, Object?>{
        'features': <String, Object?>{'ads': true},
      });
      expect(config.features.adCountdown, isTrue);
      expect(PlayerOptions.fromConfig(config).adCountdown, isTrue);
    });

    test('false switches it off', () {
      final PlayerConfig config = PlayerConfig.fromJson(<String, Object?>{
        'features': <String, Object?>{'adCountdown': false},
      });
      expect(config.features.adCountdown, isFalse);
      expect(config.features.toJson()['adCountdown'], isFalse);
      expect(PlayerOptions.fromConfig(config).adCountdown, isFalse);
    });

    test('an inline override wins', () {
      final PlayerConfig merged = mergePlayerConfig(
        PlayerConfig.defaults,
        const PlayerConfigOverride(
          features: PlayerFeaturesOverride(adCountdown: false),
        ),
      );
      expect(merged.features.adCountdown, isFalse);
    });
  });
}
