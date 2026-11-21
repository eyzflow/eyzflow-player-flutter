import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';

const source = EyzflowSource(id: 'trailer', title: 'Trailer');

void main() {
  group('buildVideoplayerRoute', () {
    const VideoplayerTarget trailer = VideoplayerTrailerTarget(
      EyzflowSource(id: 'trailer-a', title: 'Trailer A'),
    );
    const VideoplayerTarget film = VideoplayerSourceTarget(
      EyzflowSource(id: 'film-a', title: 'Film A'),
    );

    test('Tizen routes both targets to AVPlay and keeps the target', () {
      // Dart answers `linux` on a real Samsung TV, so it must route to the
      // player too.
      expect(
        buildVideoplayerRoute(operatingSystem: 'linux', target: film),
        isA<TizenAvplayRoute>().having(
          (TizenAvplayRoute route) => route.target,
          'target',
          film,
        ),
      );
      expect(
        buildVideoplayerRoute(operatingSystem: 'tizen', target: trailer),
        isA<TizenAvplayRoute>().having(
          (TizenAvplayRoute route) => route.target,
          'target',
          trailer,
        ),
      );
      expect(
        buildVideoplayerRoute(operatingSystem: 'Tizen', target: film),
        isA<TizenAvplayRoute>().having(
          (TizenAvplayRoute route) => route.target,
          'target',
          film,
        ),
      );
    });

    test('Android on a TV routes to the overlay-driven native player', () {
      for (final String os in <String>['android', 'Android']) {
        expect(
          buildVideoplayerRoute(operatingSystem: os, target: film, isTv: true),
          isA<NativeTvPlayerRoute>().having(
            (NativeTvPlayerRoute route) => route.target,
            'target',
            film,
          ),
        );
      }
    });

    test('Android off a TV keeps the plugin native controls', () {
      expect(
        buildVideoplayerRoute(
          operatingSystem: 'android',
          target: film,
          isTv: false,
        ),
        isA<NativePlayerRoute>(),
      );
    });

    test('iOS never takes the TV route', () {
      expect(
        buildVideoplayerRoute(operatingSystem: 'ios', target: film, isTv: true),
        isA<NativePlayerRoute>(),
      );
    });

    test('Tizen ignores isTv — AVPlay is the only Tizen path', () {
      expect(
        buildVideoplayerRoute(
          operatingSystem: 'tizen',
          target: film,
          isTv: true,
        ),
        isA<TizenAvplayRoute>(),
      );
    });

    test('isTv defaults to false, so existing callers are unaffected', () {
      expect(
        buildVideoplayerRoute(operatingSystem: 'android', target: film),
        isA<NativePlayerRoute>(),
      );
    });

    test('Android and iOS route both targets to the native player', () {
      for (final String os in <String>['android', 'ios', 'Android', 'IOS']) {
        expect(
          buildVideoplayerRoute(operatingSystem: os, target: film),
          isA<NativePlayerRoute>().having(
            (NativePlayerRoute route) => route.target,
            'target',
            film,
          ),
          reason: 'os=$os',
        );
        expect(
          buildVideoplayerRoute(operatingSystem: os, target: trailer),
          isA<NativePlayerRoute>().having(
            (NativePlayerRoute route) => route.target,
            'target',
            trailer,
          ),
          reason: 'os=$os',
        );
      }
    });

    test('every platform without a player implementation routes both '
        'targets to no player', () {
      for (final String? os in <String?>['macos', 'windows', null]) {
        for (final VideoplayerTarget target in <VideoplayerTarget>[
          trailer,
          film,
        ]) {
          expect(
            buildVideoplayerRoute(operatingSystem: os, target: target),
            isA<NoPlayerRoute>().having(
              (NoPlayerRoute route) => route.operatingSystem,
              'operatingSystem',
              os,
            ),
            reason: 'os=$os target=$target must not reach a player',
          );
        }
      }
    });
  });

  test(
    'disposal during controller creation disposes the late controller',
    () async {
      final controllerCreation = Completer<VideoplaybackController>();
      final controller = _ControlledController();
      final session = VideoplaybackSession(
        target: const VideoplayerTrailerTarget(source),
        createController: (_) => controllerCreation.future,
        onFinished: () {},
        onFailure: (_) {},
      );

      final start = session.start();
      await session.dispose();
      controllerCreation.complete(controller);
      await start;

      expect(controller.initializeCount, 0);
      expect(controller.playCount, 0);
      expect(controller.disposeCount, 1);
    },
  );

  test('disposal during initialization never plays the controller', () async {
    final controller = _ControlledController(deferInitialization: true);
    final session = VideoplaybackSession(
      target: const VideoplayerTrailerTarget(source),
      createController: (_) async => controller,
      onFinished: () {},
      onFailure: (_) {},
    );

    final start = session.start();
    await controller.initializeStarted.future;
    final dispose = session.dispose();
    controller.completeInitialization();
    await Future.wait([start, dispose]);

    expect(controller.playCount, 0);
    expect(controller.disposeCount, 1);
  });

  test(
    'startup timeout defers disposal until initialization settles',
    () async {
      final controller = _ControlledController(deferInitialization: true);
      final failures = <String>[];
      final session = VideoplaybackSession(
        target: const VideoplayerTrailerTarget(source),
        createController: (_) async => controller,
        onFinished: () {},
        onFailure: failures.add,
        startupTimeout: Duration.zero,
      );

      final start = session.start();
      await controller.initializeStarted.future;
      await start;

      expect(failures, ['Playback took too long to start.']);
      expect(controller.disposeCount, 0);

      final dispose = session.dispose();
      controller.completeInitialization();
      await dispose;

      expect(controller.playCount, 0);
      expect(controller.disposeCount, 1);
    },
  );

  test(
    'controller completion and asynchronous errors are bridged and removed',
    () async {
      final controller = _FakeController();
      var finishes = 0;
      final failures = <String>[];
      final session = VideoplaybackSession(
        target: const VideoplayerTrailerTarget(source),
        createController: (_) async => controller,
        onFinished: () => finishes++,
        onFailure: failures.add,
      );

      await session.start();
      controller.emit(const VideoplaybackValue(isCompleted: true));
      controller.emit(const VideoplaybackValue(errorMessage: 'late error'));
      expect(finishes, 1);
      expect(failures, ['late error']);

      await session.dispose();
      controller.emit(const VideoplaybackValue(isCompleted: true));
      expect(finishes, 1);
      expect(controller.disposeCount, 1);
    },
  );
  test('every tick is relayed, ahead of the finish and the failure', () async {
    final controller = _FakeController();
    final log = <String>[];
    final session = VideoplaybackSession(
      target: VideoplayerSourceTarget(
        EyzflowSource(
          id: 'stream',
          title: 'Episode',
          sourceType: const EyzflowFilm('episode'),
          progressSeconds: 1800,
        ),
      ),
      createController: (_) async => controller,
      onFinished: () => log.add('finished'),
      onFailure: (message) => log.add('failed $message'),
      onProgress: (position, _) => log.add('progress'),
      onValue: (value) => log.add(
        'tick ${value.position?.inSeconds} '
        '${value.isCompleted ? 'completed' : value.errorMessage ?? ''}',
      ),
    );

    await session.start();
    // Short of the resume position: withheld from progress, but an observer
    // still sees it.
    controller.emit(
      const VideoplaybackValue(
        position: Duration(seconds: 3),
        duration: Duration(minutes: 90),
      ),
    );
    controller.emit(const VideoplaybackValue(isCompleted: true));
    controller.emit(const VideoplaybackValue(errorMessage: 'boom'));

    expect(log, <String>[
      'tick 3 ',
      'tick null completed',
      'finished',
      'tick null boom',
      'failed boom',
    ]);

    await session.dispose();
    controller.emit(const VideoplaybackValue(isCompleted: true));
    expect(log, hasLength(5));
  });

  test('initialization is reported once, before the resume seek', () async {
    final controller = _FakeController()
      .._value = const VideoplaybackValue(duration: Duration(minutes: 30));
    final ready = <Duration?>[];
    final session = VideoplaybackSession(
      target: VideoplayerSourceTarget(
        EyzflowSource(
          id: 'stream',
          title: 'Episode',
          sourceType: const EyzflowFilm('episode'),
          progressSeconds: 612,
        ),
      ),
      createController: (_) async => controller,
      onFinished: () {},
      onFailure: (_) {},
      onInitialized: (value) {
        expect(controller.seekedTo, isNull);
        ready.add(value.duration);
      },
    );

    await session.start();

    expect(ready, <Duration?>[const Duration(minutes: 30)]);
    expect(controller.seekedTo, const Duration(seconds: 612));
    await session.dispose();
  });

  group('resume seek', () {
    /// The seek happens before play, so the viewer never sees the opening
    /// frames of something they were part-way through.
    test('seeks to a position inside the asset before playing', () async {
      final _FakeController controller = _FakeController()
        .._value = const VideoplaybackValue(duration: Duration(minutes: 30));
      final session = VideoplaybackSession(
        target: VideoplayerSourceTarget(
          EyzflowSource(
            id: 'stream',
            title: 'Episode',
            sourceType: const EyzflowFilm('episode'),
            progressSeconds: 612,
          ),
        ),
        createController: (_) async => controller,
        onFinished: () {},
        onFailure: (_) {},
      );

      await session.start();

      expect(controller.seekedTo, const Duration(seconds: 612));
    });

    /// A position at or past the duration would open the asset on its own end
    /// frame.
    test('ignores a position past the duration', () async {
      final _FakeController controller = _FakeController()
        .._value = const VideoplaybackValue(duration: Duration(seconds: 100));
      final session = VideoplaybackSession(
        target: VideoplayerSourceTarget(
          EyzflowSource(
            id: 'stream',
            title: 'Episode',
            sourceType: const EyzflowFilm('episode'),
            progressSeconds: 100,
          ),
        ),
        createController: (_) async => controller,
        onFinished: () {},
        onFailure: (_) {},
      );

      await session.start();

      expect(controller.seekedTo, isNull);
    });

    /// A 0 tick before the resume seek used to be recorded, overwriting the
    /// saved position; the retry then started from the beginning.
    test(
      'no progress is reported until the resume position is applied',
      () async {
        final _FakeController controller = _FakeController()
          .._value = const VideoplaybackValue(duration: Duration(minutes: 30));
        controller.duringInitialize = () => controller.emit(
          const VideoplaybackValue(
            position: Duration.zero,
            duration: Duration(minutes: 30),
          ),
        );
        final reported = <Duration>[];
        final session = VideoplaybackSession(
          target: VideoplayerSourceTarget(
            EyzflowSource(
              id: 'stream',
              title: 'Episode',
              sourceType: const EyzflowFilm('episode'),
              progressSeconds: 612,
            ),
          ),
          createController: (_) async => controller,
          onFinished: () {},
          onFailure: (_) {},
          onProgress: (position, _) => reported.add(position),
        );

        await session.start();
        controller.emit(
          const VideoplaybackValue(
            position: Duration(seconds: 612),
            duration: Duration(minutes: 30),
          ),
        );

        expect(reported, <Duration>[const Duration(seconds: 612)]);
      },
    );

    /// The seek failing leaves playback at 0; recording from there would
    /// overwrite the saved position just the same.
    test(
      'a failed resume seek records nothing until the old spot is passed',
      () async {
        final _FakeController controller = _FakeController()
          .._value = const VideoplaybackValue(duration: Duration(minutes: 30))
          ..seekThrows = true;
        final reported = <Duration>[];
        final session = VideoplaybackSession(
          target: VideoplayerSourceTarget(
            EyzflowSource(
              id: 'stream',
              title: 'Episode',
              sourceType: const EyzflowFilm('episode'),
              progressSeconds: 612,
            ),
          ),
          createController: (_) async => controller,
          onFinished: () {},
          onFailure: (_) {},
          onProgress: (position, _) => reported.add(position),
        );

        await session.start();
        for (final int seconds in <int>[0, 10, 600, 20]) {
          controller.emit(
            VideoplaybackValue(
              position: Duration(seconds: seconds),
              duration: const Duration(minutes: 30),
            ),
          );
        }

        // 600 s is within the landing slack of 612 s; once reached, a later
        // rewind to 20 s is recorded.
        expect(reported, <Duration>[
          const Duration(seconds: 600),
          const Duration(seconds: 20),
        ]);
      },
    );

    test(
      'a controller that opens at the position is not seeked again',
      () async {
        final _FakeController controller = _FakeController()
          .._value = const VideoplaybackValue(duration: Duration(minutes: 30));
        final session = VideoplaybackSession(
          target: VideoplayerSourceTarget(
            EyzflowSource(
              id: 'stream',
              title: 'Episode',
              sourceType: const EyzflowFilm('episode'),
              progressSeconds: 612,
            ),
          ),
          createController: (_) async => controller,
          onFinished: () {},
          onFailure: (_) {},
          seeksToResumePosition: false,
        );

        await session.start();

        expect(controller.seekedTo, isNull);
        expect(resumePositionFor(session.target), const Duration(seconds: 612));
      },
    );

    test('a source with no position never seeks', () async {
      final _FakeController controller = _FakeController()
        .._value = const VideoplaybackValue(duration: Duration(minutes: 30));
      final session = VideoplaybackSession(
        target: const VideoplayerTrailerTarget(source),
        createController: (_) async => controller,
        onFinished: () {},
        onFailure: (_) {},
      );

      await session.start();

      expect(controller.seekedTo, isNull);
    });
  });

  group('VideoplaybackValue', () {
    test('defaults isPlaying and isBuffering to false', () {
      const VideoplaybackValue value = VideoplaybackValue();
      expect(value.isPlaying, isFalse);
      expect(value.isBuffering, isFalse);
    });

    test('carries isPlaying and isBuffering when given', () {
      const VideoplaybackValue value = VideoplaybackValue(
        isPlaying: true,
        isBuffering: true,
      );
      expect(value.isPlaying, isTrue);
      expect(value.isBuffering, isTrue);
    });
  });
}

final class _FakeController implements VideoplaybackController {
  @override
  VideoplaybackValue get value => _value;
  VideoplaybackValue _value = const VideoplaybackValue();

  @override
  Future<void> seekTo(Duration position) async {
    if (seekThrows) throw StateError('seek refused');
    seekedTo = position;
  }

  Duration? seekedTo;
  var seekThrows = false;

  final _listeners = <void Function(VideoplaybackValue)>[];
  var disposeCount = 0;

  /// Runs inside initialize(), where real players already tick at 0.
  void Function()? duringInitialize;

  @override
  Future<void> initialize() async => duringInitialize?.call();

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  void addListener(void Function(VideoplaybackValue) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(VideoplaybackValue) listener) =>
      _listeners.remove(listener);

  @override
  Future<void> dispose() async => disposeCount++;

  void emit(VideoplaybackValue value) {
    for (final listener in List.of(_listeners)) {
      listener(value);
    }
  }
}

final class _ControlledController implements VideoplaybackController {
  @override
  VideoplaybackValue get value => _value;
  VideoplaybackValue _value = const VideoplaybackValue();

  @override
  Future<void> seekTo(Duration position) async {
    seekedTo = position;
  }

  Duration? seekedTo;

  _ControlledController({this.deferInitialization = false});

  final bool deferInitialization;
  final initializeStarted = Completer<void>();
  final _initialization = Completer<void>();
  var initializeCount = 0;
  var playCount = 0;
  var disposeCount = 0;

  @override
  Future<void> initialize() {
    initializeCount++;
    initializeStarted.complete();
    return deferInitialization ? _initialization.future : Future.value();
  }

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async {}

  @override
  void addListener(void Function(VideoplaybackValue) listener) {}

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {}

  @override
  Future<void> dispose() async => disposeCount++;

  void completeInitialization() => _initialization.complete();
}
