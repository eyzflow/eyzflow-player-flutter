import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:eyzflow_player/src/native/native_video_player.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/player_controls_bloc.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';

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
  for (final action in ['close', 'hidden', 'failure']) {
    testWidgets('startup $action preserves the saved resume position', (
      tester,
    ) async {
      final fixture = _NativeFixture(tester, delayLoad: true);
      final resumed = VideoplayerSourceTarget(
        EyzflowSource(
          id: 'resumed',
          title: 'Resumed',
          progressSeconds: 1800,
          sourceType: const EyzflowFilm('catalogue'),
        ),
      );
      await fixture.mount(target: resumed);
      await fixture.ready();
      if (action == 'hidden') {
        await fixture.event('playbackPaused', {
          'reason': 'hidden',
          'positionMs': 0,
        });
      } else if (action == 'failure') {
        fixture.loadGate.completeError(StateError('DRM failed'));
        await tester.pump();
      } else {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
      await fixture.recorder.flush();
      expect(fixture.client.writes, isEmpty);
      await fixture.dispose();
    });
  }
  testWidgets('checkpoint arms at resume and permits a later rewind', (
    tester,
  ) async {
    final fixture = _NativeFixture(tester);
    await fixture.mount(
      target: VideoplayerSourceTarget(
        EyzflowSource(
          id: 'resumed',
          title: 'Resumed',
          progressSeconds: 1800,
          sourceType: const EyzflowFilm('catalogue'),
        ),
      ),
    );
    await fixture.ready();
    await fixture.event('playbackPaused', {
      'reason': 'user',
      'positionMs': 1800000,
    });
    await fixture.event('playbackPaused', {
      'reason': 'user',
      'positionMs': 30000,
    });
    await fixture.recorder.flush();
    expect(fixture.client.writes.last, (30.0, false));
    await fixture.dispose();
  });
  testWidgets('replacement checkpoints the retired film recorder only', (
    tester,
  ) async {
    final fixture = _NativeFixture(tester);
    await fixture.mount();
    await fixture.ready();
    await fixture.event('playbackPaused', {
      'reason': 'user',
      'positionMs': 1380000,
    });
    final nextTarget = VideoplayerSourceTarget(
      EyzflowSource(
        id: 'film-b',
        title: 'Film B',
        sourceType: const EyzflowFilm('catalogue-b'),
      ),
    );
    final nextRecorder = WatchProgressRecorder(
      store: fixture.client,
      target: nextTarget,
    );
    await fixture.recorder.flush();
    fixture.client.catalogues.clear();
    await fixture.mount(target: nextTarget, recorder: nextRecorder);
    await tester.pump();
    await nextRecorder.flush();
    expect(fixture.client.catalogues, isNot(contains('catalogue-b')));
    await fixture.dispose();
  });
  for (final tv in [false, true]) {
    testWidgets(
      tv ? 'tvDisablesPip' : 'androidMetadataIncludesTitleAndPoster',
      (tester) async {
        final fixture = _NativeFixture(tester);
        await fixture.mount(tv: tv);
        expect(fixture.params['androidFullscreenRoute'], !tv);
        expect(fixture.params['androidCloseLabel'], 'Close player');
        expect(fixture.params['isFullScreen'], false); // No native dialog.
        expect(fixture.params['allowsPictureInPicture'], !tv);
        expect(fixture.params['canStartPictureInPictureAutomatically'], !tv);
        expect(fixture.params['mediaInfo'], {
          'title': 'Film',
          'artworkUrl': 'https://example.com/poster.jpg',
        });
        await fixture.ready();
        expect(
          fixture.calls.where((c) => c.method == 'playIfIntentUnchanged'),
          hasLength(1),
        );
        expect(fixture.calls.where((c) => c.method == 'play'), isEmpty);
        await fixture.dispose();
      },
    );
  }
  for (final reason in ['pipDismissed', 'closeButton']) {
    testWidgets('$reason closes the route without completing the film', (
      tester,
    ) async {
      final fixture = _NativeFixture(tester);
      await fixture.mount();
      await fixture.ready();
      await fixture.event('playbackClosed', {
        'reason': reason,
        'positionMs': 23000,
      });
      await fixture.recorder.flush();
      expect(fixture.client.writes.last, (23.0, false));
      expect(
        fixture.bloc.state.featureState,
        VideoplayerFeatureStatus.finished,
      );
      await fixture.dispose();
    });
  }
  testWidgets('nativePauseCheckpointsLatestPosition', (tester) async {
    final fixture = _NativeFixture(tester);
    await fixture.mount();
    await fixture.ready();
    await fixture.event('playbackPaused', {
      'reason': 'screenOff',
      'positionMs': 23000,
    });
    await fixture.recorder.flush();
    expect(fixture.client.writes.last, (23.0, false));
    await fixture.dispose();
  });
  testWidgets('hiddenRetryCannotStartAudio', (tester) async {
    final fixture = _NativeFixture(tester, delayMount: true);
    await fixture.mount();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    fixture.mountGate.complete(1);
    await fixture.ready();
    expect(
      fixture.calls.where(
        (c) => c.method == 'playIfIntentUnchanged' || c.method == 'play',
      ),
      isEmpty,
    );
    await fixture.dispose();
  });
  testWidgets('lateReadyUsesOriginalIntentRevision', (tester) async {
    final fixture = _NativeFixture(tester, delayLoad: true);
    await fixture.mount();
    await fixture.ready();
    fixture.revision = 8;
    fixture.loadGate.complete();
    await tester.pump();
    final call = fixture.calls.singleWhere(
      (c) => c.method == 'playIfIntentUnchanged',
    );
    expect((call.arguments as Map)['revision'], 7);
    await fixture.dispose();
  });
  testWidgets('replacedControllerCannotCloseNewRoute', (tester) async {
    final fixture = _NativeFixture(tester);
    await fixture.mount();
    await fixture.ready();
    final oldId = fixture.controller.id;
    await fixture.mount(target: _trailerB);
    await tester.pump();
    await tester.pump();
    await fixture.event('playbackClosed', {
      'reason': 'pipDismissed',
      'positionMs': 23000,
    }, id: oldId);
    expect(
      fixture.bloc.state.featureState,
      isNot(VideoplayerFeatureStatus.finished),
    );
    await fixture.dispose();
  });

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

  testWidgets('disposes the retired controller when the target changes', (
    tester,
  ) async {
    final Map<String, _TestController> controllers = <String, _TestController>{
      'trailer-a': _TestController(),
      'trailer-b': _TestController(),
    };
    Future<VideoplaybackController> createController(
      VideoplayerTarget target,
    ) async {
      final String key = switch (target) {
        VideoplayerTrailerTarget(:final source) => source.id,
        VideoplayerSourceTarget(:final source) => source.id,
      };
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
    await tester.pump();

    expect(controllers['trailer-a']!.disposeCount, 1);
    expect(controllers['trailer-b']!.initializeCount, 1);
    expect(controllers['trailer-b']!.playCount, 1);
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
    final _TestController controller = _TestController();

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(target: _trailerA),
          child: SystemVideoPlayer(
            target: _trailerA,
            createController: (VideoplayerTarget target) async => controller,
          ),
        ),
      ),
    );
    await tester.pump();
    final VideoplayerFeatureBloc bloc = BlocProvider.of<VideoplayerFeatureBloc>(
      tester.element(find.byType(SystemVideoPlayer)),
    );

    controller.emit(const VideoplaybackValue(isCompleted: true));
    await tester.pump();

    expect(bloc.state.featureState, VideoplayerFeatureStatus.finished);
  });

  testWidgets('controller error reaches the Bloc as failed', (tester) async {
    final _TestController controller = _TestController();

    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(target: _trailerA),
          child: SystemVideoPlayer(
            target: _trailerA,
            createController: (VideoplayerTarget target) async => controller,
          ),
        ),
      ),
    );
    await tester.pump();
    final VideoplayerFeatureBloc bloc = BlocProvider.of<VideoplayerFeatureBloc>(
      tester.element(find.byType(SystemVideoPlayer)),
    );

    controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
    await tester.pump();

    expect(bloc.state.featureState, VideoplayerFeatureStatus.failed);
    expect(bloc.state.errorMessage, 'boom');
  });

  testWidgets('overlay mode renders the shared controls', (tester) async {
    final _TrackingController controller = _TrackingController();

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
        useSharedOverlay: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(PlayerControls), findsOneWidget);
    expect(find.text('Trailer A'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('overlay mode drives the controller from the transport', (
    tester,
  ) async {
    final _TrackingController controller = _TrackingController();

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
        useSharedOverlay: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    final int before = controller.playCount + controller.pauseCount;
    await tester.tap(find.byKey(const Key('player_controls_play_pause')));
    await tester.pump();

    expect(controller.playCount + controller.pauseCount, greaterThan(before));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('overlay mode loads tracks once', (tester) async {
    final _TrackingController controller = _TrackingController();

    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async => controller,
        useSharedOverlay: true,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.audioTrackFetches, 1);
    expect(controller.textTrackFetches, 1);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('flipping useSharedOverlay rebuilds the controller', (
    tester,
  ) async {
    var creations = 0;
    Widget build({required bool useSharedOverlay}) => MaterialApp(
      home: Scaffold(
        body: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(target: _trailerA),
          child: SystemVideoPlayer(
            target: _trailerA,
            useSharedOverlay: useSharedOverlay,
            createController: (VideoplayerTarget target) async {
              creations++;
              return _TrackingController();
            },
          ),
        ),
      ),
    );

    await tester.pumpWidget(build(useSharedOverlay: false));
    await tester.pump();
    expect(creations, 1);
    expect(find.byType(PlayerControls), findsNothing);

    // showNativeControls is captured when the controller is built, so a flip
    // has to build a new one — otherwise the native controls stay on
    // underneath the shared overlay.
    await tester.pumpWidget(build(useSharedOverlay: true));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(creations, 2);
    expect(find.byType(PlayerControls), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the default build shows no shared overlay', (tester) async {
    await tester.pumpWidget(
      _player(
        target: _trailerA,
        createController: (VideoplayerTarget target) async =>
            _TrackingController(),
      ),
    );
    await tester.pump();

    expect(find.byType(PlayerControls), findsNothing);
  });

  group('playback events', () {
    const Duration length = Duration(minutes: 2);
    const Duration oneSecond = Duration(seconds: 1);
    const VideoplaybackValue playing = VideoplaybackValue(
      position: oneSecond,
      duration: length,
      isPlaying: true,
    );

    testWidgets('controller ticks reach the host callback, Closed last', (
      tester,
    ) async {
      final _TestController controller = _TestController();
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
      controller.emit(playing);
      controller.emit(
        const VideoplaybackValue(
          position: oneSecond,
          duration: length,
          isPaused: true,
        ),
      );
      controller.emit(playing);
      controller.emit(
        const VideoplaybackValue(
          position: oneSecond,
          duration: length,
          isBuffering: true,
        ),
      );
      controller.emit(playing);
      controller.emit(
        const VideoplaybackValue(
          position: length,
          duration: length,
          isCompleted: true,
        ),
      );
      await tester.pump();
      expect(events.last, isA<PlaybackCompleted>());

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
        PlaybackResumed(
          sourceId: 'trailer-a',
          position: oneSecond,
          duration: length,
        ),
        PlaybackBufferingStarted(
          sourceId: 'trailer-a',
          position: oneSecond,
          duration: length,
        ),
        PlaybackBufferingEnded(
          sourceId: 'trailer-a',
          position: oneSecond,
          duration: length,
        ),
        PlaybackCompleted(
          sourceId: 'trailer-a',
          position: length,
          duration: length,
        ),
        PlaybackClosed(
          sourceId: 'trailer-a',
          position: length,
          duration: length,
        ),
      ]);
    });

    testWidgets('a native error is reported once, however often it repeats', (
      tester,
    ) async {
      final _TestController controller = _TestController();
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async => controller,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();

      controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
      controller.emit(const VideoplaybackValue(errorMessage: 'boom'));
      await tester.pump();

      expect(events, const <PlaybackEvent>[
        PlaybackReady(sourceId: 'trailer-a', position: Duration.zero),
        PlaybackError(
          sourceId: 'trailer-a',
          message: 'boom',
          position: Duration.zero,
        ),
      ]);
    });

    testWidgets('a startup failure is an Error, then Closed', (tester) async {
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async =>
              _FailingController(),
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      // Never initialized, so never Ready.
      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackError,
        PlaybackClosed,
      ]);
      expect(
        (events.first as PlaybackError).message,
        startsWith('Unable to load the video source'),
      );
    });

    testWidgets('a replaced target closes its sequence and starts another', (
      tester,
    ) async {
      final List<PlaybackEvent> events = <PlaybackEvent>[];
      Future<VideoplaybackController> createController(
        VideoplayerTarget target,
      ) async => _TestController();

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: createController,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        _player(
          target: _trailerB,
          createController: createController,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(events, const <PlaybackEvent>[
        PlaybackReady(sourceId: 'trailer-a', position: Duration.zero),
        PlaybackClosed(sourceId: 'trailer-a', position: Duration.zero),
        PlaybackReady(sourceId: 'trailer-b', position: Duration.zero),
      ]);
    });

    testWidgets('a callback passed on a rebuild takes over the sequence', (
      tester,
    ) async {
      final _TestController controller = _TestController();
      final List<PlaybackEvent> first = <PlaybackEvent>[];
      final List<PlaybackEvent> second = <PlaybackEvent>[];
      Future<VideoplaybackController> createController(
        VideoplayerTarget target,
      ) async => controller;

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: createController,
          onPlaybackEvent: first.add,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: createController,
          onPlaybackEvent: second.add,
        ),
      );
      controller.emit(playing);

      expect(first.single, isA<PlaybackReady>());
      expect(second.single, isA<PlaybackStarted>());
    });

    testWidgets('overlay seeks and track switches reach the host callback', (
      tester,
    ) async {
      final _TrackingController controller = _TrackingController();
      final List<PlaybackEvent> events = <PlaybackEvent>[];

      await tester.pumpWidget(
        _player(
          target: _trailerA,
          createController: (VideoplayerTarget target) async => controller,
          useSharedOverlay: true,
          onPlaybackEvent: events.add,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final PlayerControlsBloc bloc = tester
          .element(find.byType(PlayerControls))
          .read<PlayerControlsBloc>();
      expect(bloc.state.audioTracks, isNotEmpty);
      // The fake plays from the moment play is requested.
      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
      ]);
      events.clear();

      bloc.add(const PlayerControlsSkipBy(1));
      // A skip seeks once the burst is over.
      await tester.pump(kPlayerSkipCommitDelay);
      await tester.pump();
      bloc.add(const PlayerControlsAudioSelected(0));
      await tester.pump();
      bloc.add(const PlayerControlsTextSelected(0));
      await tester.pump();
      bloc.add(const PlayerControlsTextSelected(null));
      await tester.pump();

      const Duration filmLength = Duration(seconds: 600);
      expect(events, const <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: 'trailer-a',
          from: Duration.zero,
          position: Duration(seconds: 15),
          duration: filmLength,
        ),
        // Where the seek was sent: the fake never ticks again.
        PlaybackAudioTrackChanged(
          sourceId: 'trailer-a',
          position: Duration(seconds: 15),
          duration: filmLength,
          language: 'de',
        ),
        PlaybackSubtitleTrackChanged(
          sourceId: 'trailer-a',
          position: Duration(seconds: 15),
          duration: filmLength,
          language: 'de',
        ),
        PlaybackSubtitleTrackChanged(
          sourceId: 'trailer-a',
          position: Duration(seconds: 15),
          duration: filmLength,
        ),
      ]);
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets('the native player\'s own states become events', (
      tester,
    ) async {
      final fixture = _NativeFixture(tester);
      final List<PlaybackEvent> events = <PlaybackEvent>[];
      await fixture.mount(onPlaybackEvent: events.add);
      await fixture.ready();
      expect(events.single, isA<PlaybackReady>());

      await fixture.viewEvent('play');
      // A rebuffer as the Android plugin spells it: buffering, then `loaded`
      // on the way back to playing. Neither is a pause.
      await fixture.viewEvent('buffering');
      await fixture.viewEvent('loaded');
      await fixture.viewEvent('play');
      await fixture.viewEvent('pause');
      await fixture.viewEvent('play');
      await fixture.viewEvent('error', {'message': 'decoder gave up'});
      await fixture.dispose();

      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
        PlaybackBufferingStarted,
        PlaybackBufferingEnded,
        PlaybackPaused,
        PlaybackResumed,
        PlaybackError,
        PlaybackClosed,
      ]);
      expect(
        events.every((PlaybackEvent e) => e.sourceId == 'native-film'),
        isTrue,
      );
      expect(
        events.whereType<PlaybackError>().single.message,
        'decoder gave up',
      );
    });
  });
}

/// A controller that also answers track questions, so overlay mode can be
/// exercised without a platform view.
final class _TrackingController
    implements VideoplaybackController, VideoplaybackTracks {
  var playCount = 0;
  var pauseCount = 0;
  var audioTrackFetches = 0;
  var textTrackFetches = 0;
  final List<void Function(VideoplaybackValue)> _listeners =
      <void Function(VideoplaybackValue)>[];

  @override
  VideoplaybackValue get value => const VideoplaybackValue(
    position: Duration.zero,
    duration: Duration(seconds: 600),
    isPlaying: true,
  );

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async {
    playCount++;
    for (final void Function(VideoplaybackValue) l in _listeners) {
      l(value);
    }
  }

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
  Future<List<PlayerAudioTrack>> audioTracks() async {
    audioTrackFetches++;
    return const <PlayerAudioTrack>[
      PlayerAudioTrack(trackId: 0, language: 'de'),
    ];
  }

  @override
  Future<List<PlayerTextTrack>> textTracks() async {
    textTrackFetches++;
    return const <PlayerTextTrack>[PlayerTextTrack(trackId: 0, language: 'de')];
  }

  @override
  Future<bool> selectAudioTrack(int trackId) async => true;
  @override
  Future<bool> selectTextTrack(int? trackId) async => true;
}

Widget _player({
  required VideoplayerTarget target,
  required VideoplaybackControllerFactory createController,
  bool useSharedOverlay = false,
  PlaybackEventCallback? onPlaybackEvent,
}) => MaterialApp(
  home: Scaffold(
    body: BlocProvider(
      create: (_) => VideoplayerFeatureBloc(target: target),
      child: SystemVideoPlayer(
        target: target,
        createController: createController,
        useSharedOverlay: useSharedOverlay,
        onPlaybackEvent: onPlaybackEvent,
      ),
    ),
  ),
);

/// A controller whose native player never comes up.
final class _FailingController extends _TestController {
  @override
  Future<void> initialize() async => throw StateError('no decoder');
}

base class _TestController implements VideoplaybackController {
  _TestController({this.deferDisposal = false, this.deferInitialize = false});

  @override
  VideoplaybackValue get value => _value;
  VideoplaybackValue _value = const VideoplaybackValue();

  @override
  Future<void> seekTo(Duration position) async {
    seekedTo = position;
  }

  Duration? seekedTo;

  final bool deferDisposal;
  final bool deferInitialize;
  final Completer<void> _disposal = Completer<void>();
  final Completer<void> _initialization = Completer<void>();
  var initializeCount = 0;
  var playCount = 0;
  var disposeCount = 0;
  var playedAfterInitialize = false;

  void Function(VideoplaybackValue)? _listener;

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
  void addListener(void Function(VideoplaybackValue) listener) {
    _listener = listener;
  }

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {
    if (identical(_listener, listener)) _listener = null;
  }

  @override
  Future<void> dispose() {
    disposeCount++;
    return deferDisposal ? _disposal.future : Future<void>.value();
  }

  void completeDisposal() => _disposal.complete();
  void completeInitialize() => _initialization.complete();
  void emit(VideoplaybackValue value) => _listener?.call(value);
}

final _nativeSource = EyzflowSource(
  id: 'native-film',
  title: 'Film',
  poster: Uri.parse('https://example.com/poster.jpg'),
  sourceType: const EyzflowFilm('catalogue'),
);

class _ProgressClient implements WatchProgressStore {
  final writes = <(double, bool)>[];
  final catalogues = <String>[];
  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) async {
    writes.add((progressSeconds, completed));
    catalogues.add(catalogueId);
  }
}

class _NativeFixture {
  _NativeFixture(
    this.tester, {
    this.delayMount = false,
    this.delayLoad = false,
  }) {
    recorder = WatchProgressRecorder(
      store: client,
      target: VideoplayerSourceTarget(_nativeSource),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('eyzflow_player_native'),
      (call) async {
        calls.add(call);
        if (call.method == 'setupControllerEventChannel') {
          final id = (call.arguments as Map)['controllerId'];
          final channel = MethodChannel('eyzflow_player_native_controller_$id');
          channels.add(channel);
          messenger.setMockMethodCallHandler(channel, (_) async => null);
        }
        if (call.method == 'getPlaybackIntentRevision') return revision;
        if (call.method == 'load' && delayLoad) await loadGate.future;
        if (call.method.startsWith('getAvailable')) return <Object>[];
        if (call.method.startsWith('is') ||
            call.method == 'getPictureInPictureStatus') {
          return false;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'resize') {
        final args = call.arguments as Map;
        return {'width': args['width'], 'height': args['height']};
      }
      if (call.method == 'create') {
        final args = call.arguments as Map;
        viewId = args['id'] as int;
        params = Map<String, dynamic>.from(
          const StandardMessageCodec().decodeMessage(
                ByteData.sublistView(args['params'] as Uint8List),
              )
              as Map,
        );
        final channel = MethodChannel('eyzflow_player_native_$viewId');
        channels.add(channel);
        messenger.setMockMethodCallHandler(channel, (_) async => null);
        return delayMount ? await mountGate.future : 1;
      }
      return null;
    });
  }
  final WidgetTester tester;
  final bool delayMount, delayLoad;
  final calls = <MethodCall>[];
  final channels = <MethodChannel>[];
  final mountGate = Completer<int>();
  final loadGate = Completer<void>();
  final client = _ProgressClient();
  late WatchProgressRecorder recorder;
  late VideoplayerFeatureBloc bloc;
  int revision = 7;
  int viewId = 0;
  Map<String, dynamic> params = {};
  TestDefaultBinaryMessenger get messenger =>
      tester.binding.defaultBinaryMessenger;
  NativeVideoPlayerController get controller => tester
      .widget<NativeVideoPlayer>(find.byType(NativeVideoPlayer))
      .controller;
  Future<void> mount({
    bool tv = false,
    VideoplayerTarget? target,
    WatchProgressRecorder? recorder,
    PlaybackEventCallback? onPlaybackEvent,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider(
          create: (_) => VideoplayerFeatureBloc(
            target: target ?? VideoplayerSourceTarget(_nativeSource),
          ),
          child: SystemVideoPlayer(
            target: target ?? VideoplayerSourceTarget(_nativeSource),
            useSharedOverlay: tv,
            watchProgressRecorder: recorder ?? this.recorder,
            onPlaybackEvent: onPlaybackEvent,
          ),
        ),
      ),
    );
    await tester.pump();
    bloc = tester
        .element(find.byType(SystemVideoPlayer))
        .read<VideoplayerFeatureBloc>();
  }

  Future<void> ready() async {
    await tester.pump(const Duration(milliseconds: 30));
    await messenger.handlePlatformMessage(
      'eyzflow_player_native_$viewId',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': 'isInitialized',
      }),
      (_) {},
    );
    await tester.pump();
  }

  /// A player state, on the view's own channel — where the native side
  /// reports play, pause, buffering and errors.
  Future<void> viewEvent(
    String name, [
    Map<String, Object> data = const {},
  ]) async {
    await messenger.handlePlatformMessage(
      'eyzflow_player_native_$viewId',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        ...data,
      }),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> event(String name, Map<String, Object> data, {int? id}) async {
    await messenger.handlePlatformMessage(
      'eyzflow_player_native_controller_${id ?? controller.id}',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        ...data,
      }),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await recorder.flush();
    messenger.setMockMethodCallHandler(
      const MethodChannel('eyzflow_player_native'),
      null,
    );
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}
