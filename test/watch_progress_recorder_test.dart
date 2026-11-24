import 'dart:async';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every save, and fails them with [error] when set.
class _RecordingStore implements WatchProgressStore {
  final List<(String, double, bool)> writes = <(String, double, bool)>[];
  Object? error;

  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) async {
    writes.add((catalogueId, progressSeconds, completed));
    if (error != null) throw error!;
  }
}

/// Never finishes a save until a test completes the matching completer, so
/// tests can assert on state while a write is still in flight.
class _ControlledStore extends _RecordingStore {
  final List<Completer<void>> completions = <Completer<void>>[];

  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) {
    writes.add((catalogueId, progressSeconds, completed));
    final completion = Completer<void>();
    completions.add(completion);
    return completion.future;
  }
}

EYZFlowSource _source({
  EYZFlowSourceType? sourceType = const EYZFlowFilm('episode-catalogue'),
}) => EYZFlowSource(id: 'stream', title: 'Episode', sourceType: sourceType);

void main() {
  test('pauseCheckpointsLatestPosition', () async {
    final store = _RecordingStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );
    recorder.report(const Duration(seconds: 20));
    recorder.checkpoint(const Duration(seconds: 23));
    await recorder.flush();
    expect(store.writes.last, ('episode-catalogue', 23.0, false));
    recorder.finish();
    recorder.checkpoint(const Duration(seconds: 24));
    await recorder.flush();
    expect(store.writes.last, ('episode-catalogue', 23.0, true));
  });

  test('PUT confirmation diagnostics', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    final store = _RecordingStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );
    recorder.finish();
    await recorder.flush();
    expect(store.writes, hasLength(1));
    expect(lines.join(), contains('completed=true reason=completion'));
    expect(lines.join(), contains('succeeded'));
    expect(lines.join(), isNot(contains('failed')));
  });

  test(
    'PUT result logs only after confirmation and failures expose no payload',
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = previous);
      final store = _ControlledStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );
      recorder.report(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(lines.join(), contains('watch_progress.put attempted'));
      expect(lines.join(), isNot(contains('succeeded')));
      store.completions.single.completeError(StateError('SECRET'));
      await recorder.flush();
      expect(lines.join(), contains('watch_progress.put failed'));
      expect(lines.join(), isNot(contains('SECRET')));
      expect(lines.join(), isNot(contains('succeeded')));
      expect(store.writes, hasLength(1));
    },
  );

  test('throttles writes to one per interval', () async {
    final store = _RecordingStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );

    expect(recorder.isRecording, isTrue);

    recorder.report(const Duration(seconds: 3));
    // Within the interval of the first write, so no second one.
    recorder.report(const Duration(seconds: 9));
    recorder.report(const Duration(seconds: 13));
    await recorder.flush();

    expect(store.writes, <(String, double, bool)>[
      ('episode-catalogue', 3, false),
      ('episode-catalogue', 13, false),
    ]);
  });

  test('finishing records completion once', () async {
    final store = _RecordingStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );

    recorder.report(const Duration(seconds: 30));
    recorder.finish();
    // A late tick must not reopen a completed episode.
    recorder.report(const Duration(seconds: 45));
    recorder.finish();
    await recorder.flush();

    expect(store.writes, <(String, double, bool)>[
      ('episode-catalogue', 30, false),
      ('episode-catalogue', 30, true),
    ]);
  });

  test('completion waits for an in-flight progress write', () async {
    final store = _ControlledStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );

    recorder.report(const Duration(seconds: 30));
    recorder.finish();
    await Future<void>.delayed(Duration.zero);

    expect(store.writes, <(String, double, bool)>[
      ('episode-catalogue', 30, false),
    ]);

    store.completions.single.complete();
    await Future<void>.delayed(Duration.zero);

    expect(store.writes, <(String, double, bool)>[
      ('episode-catalogue', 30, false),
      ('episode-catalogue', 30, true),
    ]);
  });

  /// A trailer shares the player and the source type but is not something a
  /// viewer resumes.
  test('a trailer records nothing', () async {
    final store = _RecordingStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerTrailerTarget(
        _source(sourceType: const EYZFlowTrailer('film')),
      ),
    );

    expect(recorder.isRecording, isFalse);
    recorder.report(const Duration(seconds: 30));
    recorder.finish();
    await recorder.flush();

    expect(store.writes, isEmpty);
  });

  /// Progress is best-effort: a failed write never surfaces to playback, and
  /// does not stop later ones.
  test('a failed write is swallowed', () async {
    final store = _RecordingStore()..error = StateError('boom');
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );

    recorder.report(const Duration(seconds: 30));
    await recorder.flush();
    store.error = null;
    recorder.checkpoint(const Duration(seconds: 31));
    await recorder.flush();

    expect(store.writes, <(String, double, bool)>[
      ('episode-catalogue', 30, false),
      ('episode-catalogue', 31, false),
    ]);
  });

  test('flush waits for a delayed save', () async {
    final store = _ControlledStore();
    final recorder = WatchProgressRecorder(
      store: store,
      target: VideoplayerSourceTarget(_source()),
    );

    recorder.report(const Duration(seconds: 30));
    bool flushed = false;
    unawaited(recorder.flush().then((_) => flushed = true));

    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);

    store.completions.single.complete();
    await recorder.flush();

    expect(flushed, isTrue);
  });

  group('completed', () {
    const film = Duration(minutes: 100);

    test('from 95 % of the duration by default', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );

      expect(recorder.completedPercent, 95);
      recorder.report(const Duration(minutes: 94), duration: film);
      recorder.report(const Duration(minutes: 95), duration: film);
      await recorder.flush();

      expect(store.writes, <(String, double, bool)>[
        ('episode-catalogue', 94 * 60, false),
        ('episode-catalogue', 95 * 60, true),
      ]);
    });

    test('a checkpoint keeps the reported duration', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
        completedPercent: 80,
      );

      recorder.report(const Duration(minutes: 70), duration: film);
      recorder.checkpoint(const Duration(minutes: 81));
      await recorder.flush();

      expect(store.writes.last, ('episode-catalogue', 81 * 60, true));
    });

    test('100 % means only the end itself', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
        completedPercent: 100,
      );

      recorder.checkpoint(const Duration(minutes: 99), duration: film);
      recorder.checkpoint(
        film - const Duration(milliseconds: 400),
        duration: film,
      );
      await recorder.flush();

      expect(store.writes, <(String, double, bool)>[
        ('episode-catalogue', 99 * 60, false),
        ('episode-catalogue', 99 * 60 + 59, true),
      ]);
    });

    test('the percent is clamped to 50–100', () {
      WatchProgressRecorder make(double percent) => WatchProgressRecorder(
        store: _RecordingStore(),
        target: VideoplayerSourceTarget(_source()),
        completedPercent: percent,
      );
      expect(make(10).completedPercent, 50);
      expect(make(150).completedPercent, 100);
      expect(make(double.nan).completedPercent, 95);
    });

    test('without a duration only finish completes', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );

      recorder.report(const Duration(minutes: 99));
      await recorder.flush();

      expect(store.writes.single, ('episode-catalogue', 99 * 60, false));
    });
  });

  group('a never-watched film', () {
    test('saves nothing at 0 s', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );

      recorder.report(Duration.zero, duration: const Duration(minutes: 90));
      recorder.checkpoint(const Duration(milliseconds: 800));
      await recorder.flush();

      expect(store.writes, isEmpty);
    });

    test('saves once it plays', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );

      recorder.checkpoint(Duration.zero);
      recorder.checkpoint(const Duration(seconds: 4));
      await recorder.flush();

      expect(store.writes, <(String, double, bool)>[
        ('episode-catalogue', 4, false),
      ]);
    });

    test('a rewind to 0 after a save is saved', () async {
      final store = _RecordingStore();
      final recorder = WatchProgressRecorder(
        store: store,
        target: VideoplayerSourceTarget(_source()),
      );

      recorder.checkpoint(const Duration(seconds: 40));
      recorder.checkpoint(Duration.zero);
      await recorder.flush();

      expect(store.writes.last, ('episode-catalogue', 0, false));
    });
  });
}
