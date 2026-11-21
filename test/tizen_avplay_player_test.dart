import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:video_player_avplay/video_player.dart';
import 'package:video_player_avplay/video_player_platform_interface.dart';
import 'package:eyzflow_player/src/bloc/player_controls_bloc.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';

const VideoplayerTarget _trailerA = VideoplayerTrailerTarget(
  EyzflowSource(id: 'trailer-a', title: 'Trailer A'),
);
const VideoplayerTarget _trailerB = VideoplayerTrailerTarget(
  EyzflowSource(id: 'trailer-b', title: 'Trailer B'),
);
const VideoplayerTarget _trailerC = VideoplayerTrailerTarget(
  EyzflowSource(id: 'trailer-c', title: 'Trailer C'),
);

void main() {
  test('selects the first native text track', () async {
    final List<TextTrack> tracks = <TextTrack>[
      TextTrack(trackId: 7, mimetype: 'text/vtt', language: 'de'),
      TextTrack(trackId: 8, mimetype: 'text/vtt', language: 'en'),
    ];
    TextTrack? selected;

    final TextTrack? result = await selectFirstTextTrack(tracks, (
      TextTrack track,
    ) async {
      selected = track;
      return true;
    });

    expect(result, same(tracks.first));
    expect(selected, same(tracks.first));
  });

  test('picks the active audio track out of the active track info', () {
    final AudioTrack audio = AudioTrack(
      trackId: 3,
      mimetype: 'audio/mp4',
      language: 'deu',
      channel: 2,
      bitrate: 128000,
    );
    final List<Track> active = <Track>[
      VideoTrack(
        trackId: 1,
        mimetype: 'video/mp4',
        width: 1920,
        height: 1080,
        bitrate: 5000000,
      ),
      audio,
      TextTrack(trackId: 4, mimetype: 'text/vtt', language: 'de'),
    ];

    expect(activeAudioTrack(active), same(audio));
    // What AVPlay answers before the track source is ready.
    expect(activeAudioTrack(const <Track>[]), isNull);
  });

  /// A controller sitting on one caption, as the plugin leaves it after a
  /// `subtitleUpdate` event.
  VideoPlayerController captioningController() =>
      VideoPlayerController.asset('subtitle-test')
        ..value = VideoPlayerValue(
          duration: DurationRange(
            const Duration(seconds: 1),
            const Duration(seconds: 2),
          ),
          size: const Size(16, 9),
          isInitialized: true,
          captions: const Captions(
            textCaptions: <TextCaption>[
              TextCaption(
                number: 0,
                start: Duration.zero,
                end: Duration(seconds: 2),
                text: 'Hallo',
              ),
            ],
          ),
        );

  testWidgets('draws nothing when the viewer has subtitles off', (
    tester,
  ) async {
    // The native track keeps decoding — AVPlay has no way to stop it — so the
    // caption events go on arriving and this widget is what has to ignore
    // them.
    final VideoPlayerController controller = captioningController();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: AvplaySubtitleOverlay(
            controller: controller,
            isEnabled: false,
          ),
        ),
      ),
    );

    expect(find.text('Hallo'), findsNothing);
    await controller.dispose();
  });

  testWidgets('renders native caption events over the video', (tester) async {
    final VideoPlayerController controller = captioningController();

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 640,
          height: 360,
          child: AvplaySubtitleOverlay(controller: controller, isEnabled: true),
        ),
      ),
    );

    expect(find.text('Hallo'), findsOneWidget);
    await controller.dispose();
  });

  // Moved from player_policy_test.dart in Task 1: startup must not
  // preflight connectivity, it just creates one controller.
  testWidgets('startup creates exactly one controller and no preflight', (
    tester,
  ) async {
    var controllerCreations = 0;

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async {
          controllerCreations++;
          return _TestController();
        },
      ),
    );
    await tester.pump();

    expect(controllerCreations, 1);
  });

  testWidgets('initializes then autoplays a trailer target', (tester) async {
    final _TestController controller = _TestController();

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
      ),
    );
    await tester.pump();

    expect(controller.initializeCount, 1);
    expect(controller.playCount, 1);
    expect(controller.playedAfterInitialize, isTrue);
    expect(controller.disposeCount, 0);
  });

  testWidgets('shows the controls overlay once startup completes', (
    tester,
  ) async {
    final _TestController controller = _TestController();

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(PlayerControls), findsOneWidget);
  });

  testWidgets('coalesces rapid replacements while disposal is pending', (
    tester,
  ) async {
    final Map<String, _TestController> controllers = {
      'trailer-a': _TestController(deferDisposal: true),
      'trailer-b': _TestController(),
      'trailer-c': _TestController(),
    };
    final List<String> created = <String>[];

    Future<VideoplaybackController> createController(
      VideoplayerTarget target,
    ) async {
      final String key = switch (target) {
        VideoplayerTrailerTarget(:final source) => source.id,
        VideoplayerSourceTarget(:final source) => source.id,
      };
      created.add(key);
      return controllers[key]!;
    }

    await tester.pumpWidget(
      _player(target: _trailerA, createController: createController),
    );
    await tester.pump();

    await tester.pumpWidget(
      _player(target: _trailerB, createController: createController),
    );
    await tester.pump();
    await tester.pumpWidget(
      _player(target: _trailerC, createController: createController),
    );
    await tester.pump();

    expect(created, <String>['trailer-a']);
    expect(controllers['trailer-a']!.disposeCount, 1);

    controllers['trailer-a']!.completeDisposal();
    await tester.pump();
    await tester.pump();

    expect(created, <String>['trailer-a', 'trailer-c']);
    expect(controllers['trailer-b']!.initializeCount, 0);
    expect(controllers['trailer-c']!.initializeCount, 1);
    expect(controllers['trailer-c']!.playCount, 1);
    expect(controllers['trailer-c']!.disposeCount, 0);
  });

  testWidgets('disposal during initialization prevents playback', (
    tester,
  ) async {
    final _TestController controller = _TestController(deferInitialize: true);

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
      ),
    );
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    controller.completeInitialize();
    await tester.pump();
    await tester.pump();

    expect(controller.playCount, 0);
    expect(controller.disposeCount, 1);
  });

  testWidgets('controller completion reaches the Bloc as finished', (
    tester,
  ) async {
    final _ListenableTestController controller = _ListenableTestController();

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(target: _trailerA),
          child: TizenAvplayPlayer(
            target: _trailerA,
            createController: (VideoplayerTarget target) async => controller,
          ),
        ),
      ),
    );
    await tester.pump();
    final VideoplayerFeatureBloc bloc = BlocProvider.of<VideoplayerFeatureBloc>(
      tester.element(find.byType(TizenAvplayPlayer)),
    );

    controller.emit(const VideoplaybackValue(isCompleted: true));
    await tester.pump();

    expect(bloc.state.featureState, VideoplayerFeatureStatus.finished);
  });

  testWidgets('controller error reaches the Bloc as failed', (tester) async {
    final _ListenableTestController controller = _ListenableTestController();

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(target: _trailerA),
          child: TizenAvplayPlayer(
            target: _trailerA,
            createController: (VideoplayerTarget target) async => controller,
          ),
        ),
      ),
    );
    await tester.pump();
    final VideoplayerFeatureBloc bloc = BlocProvider.of<VideoplayerFeatureBloc>(
      tester.element(find.byType(TizenAvplayPlayer)),
    );

    controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
    await tester.pump();

    expect(bloc.state.featureState, VideoplayerFeatureStatus.failed);
    expect(bloc.state.errorMessage, 'boom');
  });

  group('playback events', () {
    const Duration length = Duration(minutes: 2);
    const Duration oneSecond = Duration(seconds: 1);

    testWidgets('controller ticks reach the host callback, Closed last', (
      tester,
    ) async {
      final _ListenableTestController controller = _ListenableTestController();
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async => controller,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();

      // AVPlay says "playing" from the moment play is requested, stalled or
      // not, so the start waits for the stall to clear.
      controller.emit(
        const VideoplaybackValue(
          position: Duration.zero,
          duration: length,
          isPlaying: true,
          isBuffering: true,
        ),
      );
      controller.emit(
        const VideoplaybackValue(
          position: Duration.zero,
          duration: length,
          isPlaying: true,
        ),
      );
      controller.emit(
        const VideoplaybackValue(
          position: oneSecond,
          duration: length,
          isPaused: true,
        ),
      );
      controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
      controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      expect(events, const <PlaybackEvent>[
        PlaybackReady(sourceId: 'trailer-a', position: Duration.zero),
        PlaybackStarted(
          sourceId: 'trailer-a',
          position: Duration.zero,
          duration: length,
        ),
        PlaybackPaused(
          sourceId: 'trailer-a',
          position: oneSecond,
          duration: length,
        ),
        PlaybackError(
          sourceId: 'trailer-a',
          message: 'boom',
          position: oneSecond,
          duration: length,
        ),
        PlaybackClosed(
          sourceId: 'trailer-a',
          position: oneSecond,
          duration: length,
        ),
      ]);
    });

    testWidgets('playing to the end is Completed, then Closed', (tester) async {
      final _ListenableTestController controller = _ListenableTestController();
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async => controller,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();

      controller.emit(
        const VideoplaybackValue(
          position: Duration.zero,
          duration: length,
          isPlaying: true,
        ),
      );
      // AVPlay pauses itself a moment before it reports completion.
      controller.emit(
        const VideoplaybackValue(
          position: length,
          duration: length,
          isPaused: true,
        ),
      );
      controller.emit(
        const VideoplaybackValue(
          position: length,
          duration: length,
          isCompleted: true,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
        PlaybackCompleted,
        PlaybackClosed,
      ]);
    });

    testWidgets('overlay seeks and track switches reach the host callback', (
      tester,
    ) async {
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async =>
              _TestController(),
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final PlayerControlsBloc bloc = tester
          .element(find.byType(PlayerControls))
          .read<PlayerControlsBloc>();
      expect(bloc.state.textTracks, isNotEmpty);
      expect(events.single, isA<PlaybackReady>());
      events.clear();

      bloc.add(const PlayerControlsSeekRequested(Duration(minutes: 1)));
      await tester.pump();
      bloc.add(const PlayerControlsAudioSelected(1));
      await tester.pump();
      bloc.add(const PlayerControlsTextSelected(9));
      await tester.pump();
      bloc.add(const PlayerControlsTextSelected(null));
      await tester.pump();

      const Duration landed = Duration(minutes: 1);
      expect(events, const <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: 'trailer-a',
          from: Duration.zero,
          position: landed,
        ),
        PlaybackAudioTrackChanged(
          sourceId: 'trailer-a',
          position: landed,
          language: 'en',
        ),
        PlaybackSubtitleTrackChanged(
          sourceId: 'trailer-a',
          position: landed,
          language: 'de',
        ),
        PlaybackSubtitleTrackChanged(sourceId: 'trailer-a', position: landed),
      ]);
      await tester.pump(const Duration(seconds: 31));
    });
  });
}

Widget _player({
  required VideoplayerTarget target,
  required VideoplaybackControllerFactory createController,
  PlaybackEventCallback? onPlaybackEvent,
}) => MaterialApp(
  home: Scaffold(
    body: BlocProvider(
      create: (_) => VideoplayerFeatureBloc(target: target),
      child: TizenAvplayPlayer(
        target: target,
        createController: createController,
        onPlaybackEvent: onPlaybackEvent,
      ),
    ),
  ),
);

final class _TestController
    implements VideoplaybackController, VideoplaybackTracks {
  @override
  int? selectedAudioTrackId;
  @override
  int? selectedTextTrackId;
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async =>
      const <PlayerAudioTrack>[PlayerAudioTrack(trackId: 1, language: 'en')];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const <PlayerTextTrack>[
    PlayerTextTrack(trackId: 9, language: 'de'),
  ];
  @override
  Future<bool> selectAudioTrack(int trackId) async => true;
  @override
  Future<bool> selectTextTrack(int? trackId) async => true;

  @override
  VideoplaybackValue get value => _value;
  VideoplaybackValue _value = const VideoplaybackValue();

  @override
  Future<void> seekTo(Duration position) async {
    seekedTo = position;
  }

  Duration? seekedTo;

  _TestController({this.deferDisposal = false, this.deferInitialize = false});

  final bool deferDisposal;
  final bool deferInitialize;
  final Completer<void> _disposal = Completer<void>();
  final Completer<void> _initialization = Completer<void>();
  var initializeCount = 0;
  var playCount = 0;
  var disposeCount = 0;
  var playedAfterInitialize = false;

  @override
  Future<void> initialize() async {
    initializeCount++;
    if (deferInitialize) await _initialization.future;
  }

  @override
  Future<void> play() async {
    playedAfterInitialize = initializeCount > 0;
    playCount++;
  }

  @override
  Future<void> pause() async {}

  @override
  void addListener(void Function(VideoplaybackValue) listener) {}

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {}

  @override
  Future<void> dispose() {
    disposeCount++;
    return deferDisposal ? _disposal.future : Future<void>.value();
  }

  void completeDisposal() => _disposal.complete();
  void completeInitialize() => _initialization.complete();
}

/// Records the listener the adapter attaches, so a test can emit a
/// [VideoplaybackValue] and observe it reach the Bloc.
final class _ListenableTestController implements VideoplaybackController {
  @override
  VideoplaybackValue get value => _value;
  VideoplaybackValue _value = const VideoplaybackValue();

  @override
  Future<void> seekTo(Duration position) async {
    seekedTo = position;
  }

  Duration? seekedTo;

  void Function(VideoplaybackValue)? _listener;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  void addListener(void Function(VideoplaybackValue) listener) {
    _listener = listener;
  }

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {
    if (identical(_listener, listener)) _listener = null;
  }

  @override
  Future<void> dispose() async {}

  void emit(VideoplaybackValue value) => _listener?.call(value);
}
