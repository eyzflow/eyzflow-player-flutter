import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/ad_scheduler.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const VideoplayerTarget _film = VideoplayerTrailerTarget(
  EyzflowSource(id: 'film', title: 'Film'),
);

/// Stands in for Google IMA: records the requests, and the test answers
/// them through the scheduler as IMA would.
final class _FakeAds implements AdDriver {
  _FakeAds(this.hooks);

  final SystemPlayerAdHooks hooks;
  var requests = 0;
  var discards = 0;

  AdBreakScheduler get scheduler => hooks.scheduler();

  /// IMA loaded a VAST ad and played it through.
  void playAd() {
    scheduler.adsLoaded(const <Duration>[]);
    scheduler.contentPauseRequested();
    scheduler.contentResumeRequested();
  }

  @override
  void requestAds() => requests++;
  @override
  void startAds() {}
  @override
  void discardAds() => discards++;
  @override
  void contentComplete() {}
  @override
  void contentProgress(Duration position) {}
  @override
  void pauseContent() => hooks.pauseContent();
  @override
  void resumeContent() => hooks.resumeContent();
}

final class _Content implements VideoplaybackController, VideoplaybackTracks {
  final List<void Function(VideoplaybackValue)> _listeners =
      <void Function(VideoplaybackValue)>[];
  var playCount = 0;
  var initializeCount = 0;
  var pauseCount = 0;
  VideoplaybackValue _value = const VideoplaybackValue();

  void tick(num seconds, {bool playing = true}) {
    _value = VideoplaybackValue(
      position: Duration(milliseconds: (seconds * 1000).round()),
      duration: const Duration(minutes: 10),
      isPlaying: playing,
      isPaused: !playing,
    );
    for (final listener in List.of(_listeners)) {
      listener(_value);
    }
  }

  @override
  VideoplaybackValue get value => _value;
  @override
  Future<void> initialize() async => initializeCount++;
  @override
  Future<void> play() async => playCount++;
  @override
  Future<void> pause() async => pauseCount++;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  void addListener(void Function(VideoplaybackValue) listener) =>
      _listeners.add(listener);
  @override
  void removeListener(void Function(VideoplaybackValue) listener) =>
      _listeners.remove(listener);
  @override
  Future<void> dispose() async {}
  @override
  int? selectedAudioTrackId;
  @override
  int? selectedTextTrackId;
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async =>
      const <PlayerAudioTrack>[];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const <PlayerTextTrack>[];
  @override
  Future<bool> selectAudioTrack(int trackId) async => true;
  @override
  Future<bool> selectTextTrack(int? trackId) async => true;
}

final class _Fixture {
  _Fixture(this.tester, {this.markers = const <int>[], this.withAds = true});

  final PlayerAds _ads = PlayerAds(adTagUrl: 'https://ads.example.com/vast');

  final WidgetTester tester;
  final List<int> markers;
  final bool withAds;
  final _Content content = _Content();
  final List<PlaybackEvent> events = <PlaybackEvent>[];
  _FakeAds? ads;
  var markerLoads = 0;

  Future<void> mount({
    bool tv = false,
    bool adCountdown = true,
    int countdownSeconds = 5,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => VideoplayerFeatureBloc(target: _film),
            child: SystemVideoPlayer(
              target: _film,
              useSharedOverlay: tv,
              createController: (_) async => content,
              onPlaybackEvent: events.add,
              options: PlayerOptions(
                ads: withAds ? _ads : null,
                adCountdown: adCountdown,
                adCountdownSeconds: countdownSeconds,
              ),
              createAdDriver: (SystemPlayerAdHooks hooks) =>
                  ads = _FakeAds(hooks),
              loadAdBreaks: (Uri master) async {
                markerLoads++;
                expect(master.path, '/film/master.m3u8');
                return <AdBreak>[
                  for (final int s in markers)
                    AdBreak(
                      id: 'eyz-ad-$s',
                      start: Duration(seconds: s),
                    ),
                ];
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  List<Type> get eventTypes => events.map((e) => e.runtimeType).toList();
}

void main() {
  testWidgets('without ads in the config nothing is requested', (tester) async {
    final _Fixture f = _Fixture(tester, withAds: false);
    await f.mount();
    expect(f.ads, isNull);
    expect(f.markerLoads, 0);
    expect(f.content.playCount, 1);
  });

  testWidgets('Android: a pre-roll plays before the content player loads', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount();
    expect(f.ads!.requests, 1);
    // A TV has one hardware decoder: the content must not hold it yet.
    expect(f.content.initializeCount, 0);
    expect(f.content.playCount, 0);
    expect(f.eventTypes, <Type>[PlaybackAdBreakStarted]);

    f.ads!.playAd();
    await tester.pump();
    await tester.pump();
    expect(f.content.initializeCount, 1);
    expect(f.content.playCount, 1);
    expect(f.eventTypes, <Type>[
      PlaybackAdBreakStarted,
      PlaybackAdBreakEnded,
      PlaybackReady,
    ]);
    expect(f.ads!.discards, greaterThan(0));
  });

  testWidgets('iOS: the content loads while the pre-roll plays', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final _Fixture f = _Fixture(tester);
      await f.mount();
      expect(f.ads!.requests, 1);
      expect(f.content.initializeCount, 1);
      expect(f.content.playCount, 0, reason: 'held for the pre-roll');

      f.ads!.playAd();
      await tester.pump();
      expect(f.content.playCount, 1);
      expect(f.eventTypes, <Type>[
        PlaybackReady,
        PlaybackAdBreakStarted,
        PlaybackAdBreakEnded,
      ]);
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a mid-roll at its marker pauses and resumes the content', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester, markers: <int>[8]);
    await f.mount();
    expect(f.ads!.requests, 0, reason: 'no marker at the start');
    expect(f.content.playCount, 1);

    for (num t = 0; t <= 7.5; t += 0.5) {
      f.content.tick(t);
    }
    expect(f.ads!.requests, 0);
    f.content.tick(8);
    expect(f.ads!.requests, 1);
    expect(f.content.pauseCount, 1);

    f.ads!.playAd();
    await tester.pump();
    expect(f.content.playCount, 2);
    expect(
      f.eventTypes.where(
        (t) => t == PlaybackAdBreakStarted || t == PlaybackAdBreakEnded,
      ),
      <Type>[PlaybackAdBreakStarted, PlaybackAdBreakEnded],
    );
  });

  testWidgets('the TV controls are hidden and unfocusable during a break', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester, markers: <int>[8]);
    await f.mount(tv: true);
    f.content.tick(7.5);
    await tester.pump();
    expect(find.byType(PlayerControls), findsOneWidget);
    expect(
      tester
          .widget<Visibility>(
            find
                .ancestor(
                  of: find.byType(PlayerControls),
                  matching: find.byType(Visibility),
                )
                .first,
          )
          .visible,
      isTrue,
    );

    f.content.tick(8);
    await tester.pump();
    final Finder hidden = find.ancestor(
      of: find.byType(PlayerControls, skipOffstage: false),
      matching: find.byType(Visibility, skipOffstage: false),
    );
    expect(tester.widget<Visibility>(hidden.first).visible, isFalse);
    expect(
      tester
          .widget<ExcludeFocus>(
            find
                .ancestor(
                  of: find.byType(PlayerControls, skipOffstage: false),
                  matching: find.byType(ExcludeFocus, skipOffstage: false),
                )
                .first,
          )
          .excluding,
      isTrue,
    );

    f.ads!.scheduler.adsFailed();
    await tester.pump();
    expect(tester.widget<Visibility>(hidden.first).visible, isTrue);
    expect(f.content.playCount, 2, reason: 'no ad: the content plays on');
  });

  group('the countdown before a mid-roll', () {
    Finder notice() =>
        find.byKey(const ValueKey<String>('eyzflow-ad-countdown'));

    testWidgets('counts down the last 5 s, hides while paused and seeking', (
      tester,
    ) async {
      final _Fixture f = _Fixture(tester, markers: <int>[30]);
      await f.mount();
      for (num t = 20; t <= 24.5; t += 0.5) {
        f.content.tick(t);
      }
      await tester.pump();
      expect(notice(), findsNothing);

      f.content.tick(25);
      await tester.pump();
      expect(find.text('Ad in 5'), findsOneWidget);
      f.content.tick(25.5);
      f.content.tick(26);
      f.content.tick(26.5);
      f.content.tick(27);
      f.content.tick(27.5);
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);

      f.content.tick(27.5, playing: false);
      await tester.pump();
      expect(notice(), findsNothing, reason: 'paused');
      f.content.tick(28);
      await tester.pump();
      expect(find.text('Ad in 2'), findsOneWidget);

      // Seeking past the break: no notice, and no ad.
      f.content.tick(40);
      await tester.pump();
      expect(notice(), findsNothing);
      f.content.tick(40.5);
      await tester.pump();
      expect(notice(), findsNothing);
      expect(f.ads!.requests, 0);

      // Back before it: the marker still plays, and counts down again.
      f.content.tick(26);
      await tester.pump();
      expect(notice(), findsNothing, reason: 'the seek itself');
      f.content.tick(26.5);
      await tester.pump();
      expect(find.text('Ad in 4'), findsOneWidget);
      for (num t = 27; t <= 29.5; t += 0.5) {
        f.content.tick(t);
      }
      await tester.pump();
      expect(find.text('Ad in 1'), findsOneWidget);

      f.content.tick(30);
      await tester.pump();
      expect(f.ads!.requests, 1);
      expect(notice(), findsNothing, reason: 'the ad break is under way');
    });

    testWidgets('ads.countdownSeconds sets its length, without a reload', (
      tester,
    ) async {
      final _Fixture f = _Fixture(tester, markers: <int>[30]);
      await f.mount(countdownSeconds: 10);
      f.content.tick(19.5);
      await tester.pump();
      expect(notice(), findsNothing);
      f.content.tick(20);
      await tester.pump();
      expect(find.text('Ad in 10'), findsOneWidget);

      await f.mount(countdownSeconds: 3);
      f.content.tick(20.5);
      await tester.pump();
      expect(notice(), findsNothing);
      for (num t = 21; t <= 27; t += 0.5) {
        f.content.tick(t);
      }
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);
      expect(f.content.initializeCount, 1);
    });

    testWidgets('adCountdown: false shows nothing', (tester) async {
      final _Fixture f = _Fixture(tester, markers: <int>[30]);
      await f.mount(adCountdown: false);
      for (num t = 25; t <= 29.5; t += 0.5) {
        f.content.tick(t);
        await tester.pump();
        expect(notice(), findsNothing);
      }
      f.content.tick(30);
      expect(f.ads!.requests, 1, reason: 'the ad itself still plays');
    });

    testWidgets('switching it does not reload the stream', (tester) async {
      final _Fixture f = _Fixture(tester, markers: <int>[30]);
      await f.mount();
      f.content.tick(26.5);
      f.content.tick(27);
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);

      await f.mount(adCountdown: false);
      expect(notice(), findsNothing);
      await f.mount();
      f.content.tick(27.5);
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);
      expect(f.content.initializeCount, 1);
      expect(f.markerLoads, 1);
    });

    testWidgets('none without ad break markers or VMAP cue points', (
      tester,
    ) async {
      final _Fixture f = _Fixture(tester);
      await f.mount();
      f.ads!.playAd();
      await tester.pump();
      f.content.tick(26.5);
      f.content.tick(27);
      await tester.pump();
      expect(notice(), findsNothing);
    });

    testWidgets('a VMAP without markers: before its mid-roll cue points', (
      tester,
    ) async {
      final _Fixture f = _Fixture(tester);
      await f.mount();
      final AdBreakScheduler scheduler = f.ads!.scheduler;
      scheduler.adsLoaded(const <Duration>[
        Duration.zero,
        Duration(seconds: 30),
        Duration(seconds: -1),
      ]);
      scheduler.contentPauseRequested();
      scheduler.contentResumeRequested();
      await tester.pump();
      for (num t = 20; t <= 27; t += 0.5) {
        f.content.tick(t);
      }
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);

      for (num t = 27.5; t <= 30; t += 0.5) {
        f.content.tick(t);
      }
      scheduler.contentPauseRequested();
      await tester.pump();
      expect(notice(), findsNothing, reason: 'IMA plays the mid-roll');
      scheduler.contentResumeRequested();

      // Played through: a rewind does not count it down again.
      f.content.tick(26);
      f.content.tick(26.5);
      f.content.tick(27);
      await tester.pump();
      expect(notice(), findsNothing);
    });

    testWidgets('on TV it shows with the controls hidden, unfocusable', (
      tester,
    ) async {
      final _Fixture f = _Fixture(tester, markers: <int>[30]);
      await f.mount(tv: true);
      f.content.tick(26.5);
      f.content.tick(27);
      await tester.pump();
      expect(find.text('Ad in 3'), findsOneWidget);
      expect(
        find.ancestor(of: notice(), matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      expect(
        tester
            .widget<ExcludeFocus>(
              find
                  .ancestor(of: notice(), matching: find.byType(ExcludeFocus))
                  .first,
            )
            .excluding,
        isTrue,
      );
      // Not inside the controls, which hide when idle.
      expect(
        find.ancestor(of: notice(), matching: find.byType(PlayerControls)),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });
}
