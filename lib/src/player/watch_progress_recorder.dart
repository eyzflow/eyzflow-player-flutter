import '../core/source.dart';

import 'playback_target.dart';
import 'player_log.dart';

/// How often a playing asset reports its position to EYZFlow.
///
/// The native controller notifies on every position tick, so writes are
/// throttled to this interval. An abrupt dismissal therefore loses at most this
/// much position.
const Duration watchProgressWriteInterval = Duration(seconds: 10);

/// Where watch progress goes: the app's watch history, e.g. its call to the
/// EYZFlow watch-history API:
///
/// ```dart
/// final class MyWatchHistory implements WatchProgressStore {
///   @override
///   Future<void> save({
///     required String catalogueId,
///     required double progressSeconds,
///     required bool completed,
///   }) => api.saveProgress(catalogueId, progressSeconds, completed);
/// }
/// ```
// A named extension point the app implements.
// ignore: one_member_abstracts
abstract interface class WatchProgressStore {
  /// Saves the position of [catalogueId]. A failure is logged and never
  /// interrupts playback; a later save tries again.
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  });
}

/// Records what the viewer has watched, on a throttle.
///
/// Progress is best-effort: a failed write is logged and never interrupts
/// playback. Nothing reads a position back to confirm a write, because the
/// watch-history read is eventually consistent. Writes go through the app's
/// [store], so they land wherever the rest of the app reads watch history.
final class WatchProgressRecorder {
  WatchProgressRecorder({
    required this.store,
    required VideoplayerTarget target,
  }) : _catalogueId = _catalogueIdOf(target);

  final WatchProgressStore store;

  /// The catalogue to record against, or `null` when this asset has no
  /// progress of its own.
  final String? _catalogueId;

  Duration? _lastWritten;
  bool _finished = false;
  Future<void> _writes = Future<void>.value();

  /// Whether this asset records progress at all.
  ///
  /// Trailers do not: they share the player and the source type but are not
  /// something a viewer resumes.
  bool get isRecording => _catalogueId != null;

  /// Reports a position, writing only once per [watchProgressWriteInterval].
  void report(Duration position) {
    if (_catalogueId == null || _finished) return;
    final Duration? last = _lastWritten;
    if (last != null && (position - last).abs() < watchProgressWriteInterval) {
      return;
    }
    _lastWritten = position;
    _write(position, completed: false);
  }

  /// Saves the latest position immediately on pause or exit, without completing.
  void checkpoint(Duration position) {
    if (_catalogueId == null || _finished) return;
    _lastWritten = position;
    _write(position, completed: false);
  }

  /// Records the finished asset. Further reports are ignored, so a late tick
  /// cannot reopen a completed episode.
  void finish() {
    if (_catalogueId == null || _finished) return;
    _finished = true;
    _write(_lastWritten ?? Duration.zero, completed: true);
  }

  void _write(Duration position, {required bool completed}) {
    final String catalogueId = _catalogueId!;
    final double seconds = position.inSeconds.toDouble();
    _writes = _writes.then((_) async {
      final elapsed = Stopwatch()..start();
      logPlayback(
        'watch_progress.put attempted content_id=$catalogueId '
        'position_s=$seconds completed=$completed '
        'reason=${completed ? 'completion' : 'progress'}',
      );
      try {
        await store.save(
          catalogueId: catalogueId,
          progressSeconds: seconds,
          completed: completed,
        );
        logPlayback(
          'watch_progress.put succeeded duration_ms=${elapsed.elapsedMilliseconds}',
        );
      } catch (error) {
        // Keep the queue successful so a failed progress write cannot prevent
        // a later progress or completion write.
        logPlayback('watch_progress.put failed', error: error);
      }
    });
  }

  /// Awaits every write queued so far, including one still in flight.
  ///
  /// The player calls this before it dismisses, so a report or completion
  /// issued just before the viewer left is not lost to a torn-down recorder.
  /// Reads nothing back.
  Future<void> flush() => _writes;

  static String? _catalogueIdOf(VideoplayerTarget target) => switch (target) {
    VideoplayerSourceTarget(:final source) => switch (source.sourceType) {
      EYZFlowFilm(:final catalogueId) => catalogueId,
      _ => null,
    },
    VideoplayerTrailerTarget() => null,
  };
}
