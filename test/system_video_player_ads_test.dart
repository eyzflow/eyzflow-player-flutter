import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/ad_scheduler.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
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
  Future<void> initialize() async {}
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

  final WidgetTester tester;
  final List<int> markers;
  final bool withAds;
  final _Content content = _Content();
  final List<PlaybackEvent> events = <PlaybackEvent>[];
  _FakeAds? ads;
  var markerLoads = 0;

  Future<void> mount({bool tv = false}) async {
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
                ads: withAds
                    ? PlayerAds(adTagUrl: 'https://ads.example.com/vast')
                    : null,
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

  testWidgets('a pre-roll plays before the content starts', (tester) async {
    final _Fixture f = _Fixture(tester);
    await f.mount();
    expect(f.ads!.requests, 1);
    expect(f.content.playCount, 0, reason: 'held for the pre-roll');
    expect(f.eventTypes, contains(PlaybackAdBreakStarted));

    f.ads!.playAd();
    await tester.pump();
    expect(f.content.playCount, 1);
    expect(f.eventTypes.last, PlaybackAdBreakEnded);
    expect(f.ads!.discards, greaterThan(0));
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
}
