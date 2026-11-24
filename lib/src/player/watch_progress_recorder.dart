import '../core/player_config.dart'
    show defaultWatchProgressCompletedPercent, watchProgressCompletedPercent;
import '../core/source.dart';

import 'playback_target.dart';
import 'player_log.dart';

/// How often a playing asset reports its position to EYZFlow.
///
/// The native controller notifies on every position tick, so writes are
/// throttled to this interval. An abrupt dismissal therefore loses at most this
/// much position.
const Duration watchProgressWriteInterval = Duration(seconds: 10);

/// Where watch progress goes. `EYZFlowPlayer` saves to the EYZFlow watch
/// history (`EYZFlowWatchHistoryStore`) by default; an app that keeps its own
/// watch history implements this instead:
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
/// watch-history read is eventually consistent. Writes go through [store]:
/// the EYZFlow watch history (`EYZFlowWatchHistoryStore`) or the app's own.
///
/// A save counts as completed once the position reaches [completedPercent]
/// of the duration (100: only the end), and always on [finish]. A film that
/// was opened and closed at once saves nothing: the first save is never one
/// at 0 seconds that is not completed, so it does not show in "Continue
/// watching".
final class WatchProgressRecorder {
  WatchProgressRecorder({
    required this.store,
    required VideoplayerTarget target,
    double completedPercent = defaultWatchProgressCompletedPercent,
  }) : _catalogueId = _catalogueIdOf(target),
       completedPercent = watchProgressCompletedPercent(completedPercent);

  final WatchProgressStore store;

  /// From this share of the film on (50–100 %), a save counts as completed.
  final double completedPercent;

  /// The catalogue to record against, or `null` when this asset has no
  /// progress of its own.
  final String? _catalogueId;

  Duration? _lastWritten;
  Duration? _latest;
  Duration? _duration;
  (int, bool)? _lastSaved;
  bool _finished = false;
  Future<void> _writes = Future<void>.value();

  /// Whether this asset records progress at all.
  ///
  /// Trailers do not: they share the player and the source type but are not
  /// something a viewer resumes.
  bool get isRecording => _catalogueId != null;

  /// Reports a position, writing only once per [watchProgressWriteInterval].
  /// [duration], when known, decides whether the film counts as watched; the
  /// last one reported is kept for later saves.
  void report(Duration position, {Duration? duration}) {
    if (_catalogueId == null || _finished) return;
    _track(position, duration);
    final Duration? last = _lastWritten;
    if (last != null && (position - last).abs() < watchProgressWriteInterval) {
      return;
    }
    _lastWritten = position;
    _write(position, completed: _isCompleted(position));
  }

  /// Saves the latest position immediately on pause or exit. It counts as
  /// completed past [completedPercent] of the duration.
  void checkpoint(Duration position, {Duration? duration}) {
    if (_catalogueId == null || _finished) return;
    _track(position, duration);
    _lastWritten = position;
    _write(position, completed: _isCompleted(position));
  }

  /// Records the finished asset. Further reports are ignored, so a late tick
  /// cannot reopen a completed episode.
  void finish() {
    if (_catalogueId == null || _finished) return;
    _finished = true;
    _write(_latest ?? _lastWritten ?? Duration.zero, completed: true);
  }

  void _track(Duration position, Duration? duration) {
    _latest = position;
    if (duration != null && duration > Duration.zero) _duration = duration;
  }

  bool _isCompleted(Duration position) {
    final Duration? duration = _duration;
    if (duration == null) return false;
    if (completedPercent >= 100) {
      return position >= duration - const Duration(milliseconds: 500);
    }
    return position.inMicroseconds >=
        duration.inMicroseconds * completedPercent / 100;
  }

  void _write(Duration position, {required bool completed}) {
    final String catalogueId = _catalogueId!;
    final int whole = position.inSeconds;
    final (int, bool)? last = _lastSaved;
    // Opening a film and leaving at once doesn't put it in "Continue
    // watching".
    if (last == null && whole <= 0 && !completed) return;
    // The same save again changes nothing.
    if (last == (whole, completed)) return;
    _lastSaved = (whole, completed);
    final double seconds = whole.toDouble();
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
