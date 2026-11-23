import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const VideoplayerTarget _film = VideoplayerTrailerTarget(
  EYZFlowSource(id: 'film', title: 'Film'),
);

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

final List<StreamSignal> _signals = <StreamSignal>[
  StreamSignal(
    id: 'eyz-intro',
    type: StreamSignalType.intro,
    start: _s(5),
    end: _s(65),
  ),
  StreamSignal(
    id: 'eyz-closing-credits',
    type: StreamSignalType.closingCredits,
    start: _s(540),
    end: _s(600),
  ),
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
  final List<PlaybackEvent> events = <PlaybackEvent>[];
  Uri? loadedFrom;

  Future<void> mount({
    bool tv = false,
    bool skipButtons = true,
    PlayerSkipButtonTypes types = const PlayerSkipButtonTypes(),
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
                skipButtons: skipButtons,
                skipButtonTypes: types,
              ),
              loadSignals: (Uri master) async {
                loadedFrom = master;
                return _signals;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Iterable<PlaybackEvent> get signalEvents => events.where(
    (PlaybackEvent e) => e is PlaybackSignalStarted || e is PlaybackSignalEnded,
  );
}

Finder _button() => find.byKey(const ValueKey<String>('eyzflow-skip-signal'));

void main() {
  testWidgets(
    'phone: "Skip intro" while in the intro; a tap jumps to its end',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount();
      expect(f.loadedFrom?.path, '/film/master.m3u8');

      f.content.tick(4);
      await tester.pump();
      expect(_button(), findsNothing);

      f.content.tick(5.5);
      await tester.pump();
      expect(find.text('Skip intro'), findsOneWidget);

      await tester.tap(find.text('Skip intro'));
      await tester.pump();
      expect(f.content.seeks, <Duration>[_s(65)]);
      expect(_button(), findsNothing);
      expect(f.signalEvents.map((e) => e.runtimeType), <Type>[
        PlaybackSignalStarted,
        PlaybackSignalEnded,
      ]);
      expect(f.events.whereType<PlaybackSeeked>().single.position, _s(65));

      // A report from before the seek landed does not bring it back.
      f.content.tick(6);
      await tester.pump();
      expect(_button(), findsNothing);

      // Once the seek landed, seeking back into the intro brings it back.
      f.content.tick(65);
      await tester.pump();
      f.content.tick(20);
      await tester.pump();
      expect(find.text('Skip intro'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('phone: credits that run to the end skip to the end', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(types: const PlayerSkipButtonTypes(closingCredits: true));
    f.content.tick(545);
    await tester.pump();
    expect(find.text('Skip credits'), findsOneWidget);
    final PlaybackSignalStarted started = f.events
        .whereType<PlaybackSignalStarted>()
        .single;
    expect(started.signal.type, StreamSignalType.closingCredits);

    await tester.tap(_button());
    await tester.pump();
    expect(f.content.seeks, <Duration>[const Duration(minutes: 10)]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('skipButtons off: no button, the events still come', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(skipButtons: false);
    f.content.tick(6);
    await tester.pump();
    expect(_button(), findsNothing);
    expect(
      f.events.whereType<PlaybackSignalStarted>().single.signal.id,
      'eyz-intro',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TV: with the controls hidden the button takes focus and OK '
      'skips; with them up OK is theirs', (tester) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(tv: true);
    expect(find.byType(PlayerControls), findsOneWidget);

    f.content.tick(6);
    await tester.pump();
    // The overlay is up after start: no button over it, and OK acts on the
    // focused control (play/pause), not the signal.
    expect(_button(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(f.content.seeks, isEmpty);

    // Idle: the overlay fades out and focus goes to the button.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Skip intro'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'controls.skipSignal',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(f.content.seeks, <Duration>[_s(65)]);
    expect(_button(), findsNothing);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'controls.playPause',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'closing credits get no skip button by default; the event still comes',
    (tester) async {
      final _Fixture f = _Fixture(tester);
      await f.mount();
      f.content.tick(545);
      await tester.pump();
      expect(_button(), findsNothing);
      expect(
        f.events.whereType<PlaybackSignalStarted>().single.signal.type,
        StreamSignalType.closingCredits,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('skipButtonTypes turns one type off and leaves the others', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester);
    await f.mount(types: const PlayerSkipButtonTypes(intro: false));
    f.content.tick(6);
    await tester.pump();
    expect(_button(), findsNothing);
    expect(
      const PlayerSkipButtonTypes(intro: false).allows(StreamSignalType.recap),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
