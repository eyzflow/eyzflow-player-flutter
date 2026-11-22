import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/end_screen/end_screen.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const VideoplayerTarget _film = VideoplayerTrailerTarget(
  EyzflowSource(id: 'film', title: 'Film'),
);

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

/// Closing credits from 9:00 to the end of the 10-minute film.
final List<StreamSignal> _signals = <StreamSignal>[
  StreamSignal(
    id: 'eyz-closing-credits',
    type: StreamSignalType.closingCredits,
    start: _s(540),
    end: _s(600),
  ),
];

const EyzflowEndScreenItem _next = EyzflowEndScreenItem(
  streamId: 'ep2',
  title: 'Episode 2',
  badge: 'S1 E2',
);

const List<EyzflowEndScreenItem> _films = <EyzflowEndScreenItem>[
  EyzflowEndScreenItem(
    streamId: 'a',
    title: 'Film A',
    duration: Duration(minutes: 92),
  ),
  EyzflowEndScreenItem(streamId: 'b', title: 'Film B'),
  EyzflowEndScreenItem(streamId: 'c', title: 'Film C'),
];

final class _Content implements VideoplaybackController, VideoplaybackTracks {
  final List<void Function(VideoplaybackValue)> _listeners =
      <void Function(VideoplaybackValue)>[];
  final List<Duration> seeks = <Duration>[];
  VideoplaybackValue _value = const VideoplaybackValue();

  void tick(num seconds) {
    _value = VideoplaybackValue(
      position: _s(seconds),
      duration: const Duration(minutes: 10),
      isPlaying: true,
    );
    for (final listener in List.of(_listeners)) {
      listener(_value);
    }
  }

  /// The film played to its end.
  void complete() {
    _value = const VideoplaybackValue(
      position: Duration(minutes: 10),
      duration: Duration(minutes: 10),
      isCompleted: true,
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
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);
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
  _Fixture(this.tester);

  final WidgetTester tester;
  final _Content content = _Content();
  final List<String> picked = <String>[];
  final List<EndScreenSelection> selections = <EndScreenSelection>[];

  Future<void> mount({
    bool tv = false,
    EyzflowEndScreen? endScreen,
    PlayerOverlayBuilder? overlayBuilder,
    PlayerConfig config = PlayerConfig.defaults,
    List<StreamSignal>? signals,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => VideoplayerFeatureBloc(target: _film),
            child: PlayerOverlayScope(
              settings: EndScreenSettings.resolve(config, endScreen),
              endScreen: endScreen,
              overlayBuilder: overlayBuilder,
              onPick: (EyzflowEndScreenItem item) => picked.add(item.streamId),
              child: SystemVideoPlayer(
                target: _film,
                useSharedOverlay: tv,
                createController: (_) async => content,
                loadSignals: (Uri master) async => signals ?? _signals,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  EyzflowEndScreen endScreen({int? autoplaySeconds, bool prevent = false}) =>
      EyzflowEndScreen(
        nextUp: _next,
        items: _films,
        autoplaySeconds: autoplaySeconds,
        onSelect: (EndScreenSelection s) {
          selections.add(s);
          if (prevent) s.preventDefault();
        },
      );
}

Finder _endScreen() => find.byKey(const ValueKey<String>('eyzflow-end-screen'));
Finder _key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  group('end screen settings', () {
    test('on with something to show; the app over the config', () {
      final EyzflowEndScreen options = const EyzflowEndScreen(items: _films);
      final EndScreenSettings defaults = EndScreenSettings.resolve(
        PlayerConfig.defaults,
        options,
      );
      expect(defaults.enabled, isTrue);
      expect(defaults.autoplaySeconds, 10);
      expect(defaults.showAt, EndScreenShowAt.credits);
      expect(defaults.shrinkVideo, isTrue);
      expect(
        EndScreenSettings.resolve(PlayerConfig.defaults, null).enabled,
        isFalse,
      );
      expect(
        EndScreenSettings.resolve(
          PlayerConfig.defaults,
          const EyzflowEndScreen(),
        ).enabled,
        isFalse,
      );

      const PlayerConfig remote = PlayerConfig(
        features: PlayerFeatures(endScreen: true),
        endScreen: PlayerEndScreenConfig(
          autoplaySeconds: 5,
          showAt: EndScreenShowAt.end,
          shrinkVideo: false,
        ),
      );
      final EndScreenSettings fromRemote = EndScreenSettings.resolve(
        remote,
        options,
      );
      expect(fromRemote.autoplaySeconds, 5);
      expect(fromRemote.showAt, EndScreenShowAt.end);
      expect(fromRemote.shrinkVideo, isFalse);
      expect(
        EndScreenSettings.resolve(
          remote,
          const EyzflowEndScreen(items: _films, autoplaySeconds: 99),
        ).autoplaySeconds,
        30,
      );
      expect(
        EndScreenSettings.resolve(
          const PlayerConfig(features: PlayerFeatures(endScreen: false)),
          options,
        ).enabled,
        isFalse,
      );
    });

    test('phases: the credits, the end, or not now', () {
      final EndScreenSettings on = EndScreenSettings.resolve(
        PlayerConfig.defaults,
        const EyzflowEndScreen(items: _films),
      );
      expect(
        endScreenPhase(on, _signals.first, ended: false),
        EndScreenPhase.credits,
      );
      expect(endScreenPhase(on, null, ended: true), EndScreenPhase.ended);
      expect(endScreenPhase(on, null, ended: false), isNull);
      final EndScreenSettings atEnd = EndScreenSettings(
        enabled: true,
        autoplaySeconds: 10,
        showAt: EndScreenShowAt.end,
        shrinkVideo: true,
      );
      expect(endScreenPhase(atEnd, _signals.first, ended: false), isNull);
      expect(formatRuntime(const Duration(minutes: 92)), '1 h 32 min');
      expect(formatRuntime(const Duration(minutes: 45)), '45 min');
      expect(formatRuntime(null), '');
    });
  });

  testWidgets(
    'phone: at the credits the video shrinks, Up next counts down and plays in place',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount(endScreen: f.endScreen(autoplaySeconds: 3));
      f.content.tick(500);
      await tester.pump();
      expect(_endScreen(), findsNothing);

      f.content.tick(541);
      await tester.pump();
      await tester.pump();
      expect(_endScreen(), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);
      expect(find.text('Film A'), findsOneWidget);
      expect(find.text('1 h 32 min'), findsOneWidget);
      expect(find.text('Next in 3'), findsOneWidget);
      // The skip button stays away while the end screen shows.
      expect(
        find.byKey(const ValueKey<String>('eyzflow-skip-signal')),
        findsNothing,
      );
      // The small video in the corner goes back to the credits when tapped.
      expect(_key('eyzflow-end-screen-video'), findsOneWidget);

      f.content.tick(542);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Next in 2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(f.picked, <String>['ep2']);
      expect(f.selections.single.autoplay, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone: picking a film plays it; preventDefault leaves it to the app',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount(endScreen: f.endScreen(prevent: true));
      f.content.tick(541);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Film B'));
      await tester.pump();
      expect(f.selections.single.item.streamId, 'b');
      expect(f.selections.single.autoplay, isFalse);
      expect(f.picked, isEmpty, reason: 'prevented');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone: Cancel stops the countdown; Back goes to the credits until the end',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount(endScreen: f.endScreen(autoplaySeconds: 2));
      f.content.tick(541);
      await tester.pump();
      await tester.pump();
      await tester.tap(_key('eyzflow-end-screen-cancel'));
      await tester.pump(const Duration(seconds: 3));
      expect(f.picked, isEmpty);
      expect(find.text('Play'), findsOneWidget);

      await tester.tap(_key('eyzflow-end-screen-back'));
      await tester.pump();
      expect(_endScreen(), findsNothing);
      f.content.tick(560);
      await tester.pump();
      expect(_endScreen(), findsNothing, reason: 'still the credits');

      // In the last second it is the end: the end screen comes back.
      f.content.tick(599.5);
      await tester.pump();
      await tester.pump();
      expect(_endScreen(), findsOneWidget);
      expect(_key('eyzflow-end-screen-back'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('features.endScreen off, or no items: nothing changes', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(
      endScreen: f.endScreen(),
      config: const PlayerConfig(features: PlayerFeatures(endScreen: false)),
    );
    f.content.tick(541);
    await tester.pump();
    await tester.pump();
    expect(_endScreen(), findsNothing);
    // No "Skip credits" either: the closing credits have no skip button by
    // default (skipButtonTypes).
    expect(
      find.byKey(const ValueKey<String>('eyzflow-skip-signal')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("the app's overlay wins over the end screen", (tester) async {
    final _Fixture f = _Fixture(tester);
    PlayerOverlayContext? seen;
    await f.mount(
      endScreen: f.endScreen(),
      overlayBuilder: (BuildContext context, PlayerOverlayContext o) {
        seen = o;
        return o.signal?.type == StreamSignalType.closingCredits
            ? const Align(
                alignment: Alignment.bottomRight,
                child: Text('My similar films'),
              )
            : null;
      },
    );
    f.content.tick(541);
    await tester.pump();
    await tester.pump();
    expect(find.text('My similar films'), findsOneWidget);
    expect(_endScreen(), findsNothing);
    expect(seen?.ended, isFalse);
    seen!.controls.dismiss();
    await tester.pump();
    await tester.pump();
    expect(find.text('My similar films'), findsNothing);
    // Dismissed, the end screen does not stand in for it.
    expect(_endScreen(), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'TV: the end screen takes the focus; Select plays the next stream',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount(tv: true, endScreen: f.endScreen(autoplaySeconds: 0));
      f.content.tick(541);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(_endScreen(), findsOneWidget);
      bool focusOnEndScreen() {
        bool inside = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          Element e,
        ) {
          if (e.widget.key ==
              const ValueKey<String>('eyzflow-end-screen-play')) {
            inside = true;
            return false;
          }
          return true;
        });
        return inside;
      }

      expect(focusOnEndScreen(), isTrue, reason: 'Play has the focus');
      // The idle overlay hides and must not take the focus back.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 1));
      expect(focusOnEndScreen(), isTrue, reason: 'still on Play');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(f.picked, <String>['ep2']);
      expect(f.selections.single.autoplay, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'without a closing credits signal the last 20 s count as the credits',
    () {
      final EndScreenSettings on = EndScreenSettings.resolve(
        PlayerConfig.defaults,
        const EyzflowEndScreen(items: _films),
      );
      expect(on.secondsBeforeEnd, 20);
      EndScreenPhase? at(num s, {bool credits = false}) => endScreenPhase(
        on,
        null,
        ended: false,
        position: _s(s),
        duration: _s(600),
        hasClosingCredits: credits,
      );
      expect(at(579), isNull);
      expect(at(580), EndScreenPhase.credits);
      expect(at(590, credits: true), isNull, reason: 'the signal decides then');
      const PlayerConfig remote = PlayerConfig(
        endScreen: PlayerEndScreenConfig(secondsBeforeEnd: 0),
      );
      final EndScreenSettings off = EndScreenSettings.resolve(
        remote,
        const EyzflowEndScreen(items: _films),
      );
      expect(
        endScreenPhase(
          off,
          null,
          ended: false,
          position: _s(595),
          duration: _s(600),
          hasClosingCredits: false,
        ),
        isNull,
      );
      expect(
        EndScreenSettings.resolve(
          PlayerConfig.defaults,
          const EyzflowEndScreen(items: _films, secondsBeforeEnd: 500),
        ).secondsBeforeEnd,
        120,
      );
    },
  );

  testWidgets(
    'phone: a stream without closing credits gets it 20 s before the end',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount(endScreen: f.endScreen(), signals: const <StreamSignal>[]);
      f.content.tick(570);
      await tester.pump();
      await tester.pump();
      expect(_endScreen(), findsNothing);
      f.content.tick(582);
      await tester.pump();
      await tester.pump();
      expect(_endScreen(), findsOneWidget);
      expect(
        _key('eyzflow-end-screen-video'),
        findsOneWidget,
        reason: 'shrunk, as at the credits',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('at the end the player stays open on the end screen', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(endScreen: f.endScreen(autoplaySeconds: 0));
    f.content.complete();
    await tester.pump();
    await tester.pump();
    expect(_endScreen(), findsOneWidget);
    final VideoplayerFeatureBloc bloc = tester
        .element(find.byType(SystemVideoPlayer))
        .read<VideoplayerFeatureBloc>();
    expect(
      bloc.state.featureState,
      isNot(VideoplayerFeatureStatus.finished),
      reason: 'the player stays open on the end screen',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('at the end without an end screen the player closes as before', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount();
    f.content.complete();
    await tester.pump();
    await tester.pump();
    final VideoplayerFeatureBloc bloc = tester
        .element(find.byType(SystemVideoPlayer))
        .read<VideoplayerFeatureBloc>();
    expect(bloc.state.featureState, VideoplayerFeatureStatus.finished);
    await tester.pumpWidget(const SizedBox());
  });
}
