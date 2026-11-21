import 'beat.dart';

/// Where the impression is. Time is added to the state being left.
enum BeatState { startup, playing, paused, buffering, seeking, ended, error }

/// Milliseconds on a monotonic clock.
typedef MonotonicClock = int Function();

const int _maxErrors = 20;

/// A buffering that starts this soon after a seek is the seek loading, not a
/// stall: the web player counts neither (`seeking` state).
const int _seekSettleMs = 3000;

/// Watches one impression (one video loaded in the player) and keeps its
/// quality counters: how long it took to start, how long it played, paused
/// and stalled, how often it stalled and was sought, and its errors.
///
/// The web player's `AnalyticsCollector`, fed by calls instead of DOM events:
/// the player reports state changes as `PlaybackEvent`s, which
/// `PlaybackEventAdapter` turns into these calls. Pure Dart.
final class BeatCollector {
  BeatCollector({MonotonicClock? now}) : _now = now ?? _stopwatchClock() {
    _createdAt = _now();
    _since = _createdAt;
  }

  final MonotonicClock _now;
  late final int _createdAt;
  late int _since;
  BeatState _state = BeatState.startup;
  var _ready = false;
  var _everPlayed = false;
  int? _playerStartupMs;
  int? _videoStartupMs;
  var _playedMs = 0;
  var _pausedMs = 0;
  var _rebufferMs = 0;
  var _rebufferCount = 0;
  var _seekCount = 0;
  double _maxPositionS = 0;
  double? _durationS;
  double? _positionS;
  var _positionAt = 0;
  int? _lastSeekAt;
  var _errorCount = 0;
  var _pending = <BeatError>[];

  /// Called on the first frame and on errors, so the transport sends a beat
  /// at once.
  void Function()? onMilestone;

  BeatState get state => _state;

  /// The player is initialized and can play: its own startup is over.
  void ready({Duration? position, Duration? duration}) {
    _observe(position, duration);
    if (_ready) return;
    _ready = true;
    _playerStartupMs = _now() - _createdAt;
  }

  /// The player reports playing. The first time, that is the first frame.
  void playing({Duration? position, Duration? duration}) {
    _observe(position, duration);
    if (!_everPlayed) {
      _everPlayed = true;
      if (!_ready) ready();
      _videoStartupMs = _now() - _createdAt;
      _enter(BeatState.playing);
      onMilestone?.call();
      return;
    }
    if (_state == BeatState.ended || _state == BeatState.error) return;
    _enter(BeatState.playing);
  }

  void paused({Duration? position, Duration? duration}) {
    _observe(position, duration);
    if (!_everPlayed) return;
    if (_state == BeatState.ended || _state == BeatState.error) return;
    _enter(BeatState.paused);
  }

  void bufferingStarted({Duration? position, Duration? duration}) {
    _observe(position, duration);
    if (!_everPlayed || _state != BeatState.playing) return;
    final lastSeek = _lastSeekAt;
    if (lastSeek != null && _now() - lastSeek <= _seekSettleMs) {
      _enter(BeatState.seeking);
      return;
    }
    _rebufferCount += 1;
    _enter(BeatState.buffering);
  }

  /// Buffering ended; [isPlaying] says whether playback carries on.
  void bufferingEnded({
    Duration? position,
    Duration? duration,
    bool isPlaying = true,
  }) {
    _observe(position, duration);
    if (_state != BeatState.buffering && _state != BeatState.seeking) return;
    _enter(isPlaying ? BeatState.playing : BeatState.paused);
  }

  void seeked({required Duration to, Duration? duration}) {
    if (!_everPlayed || _state == BeatState.ended) {
      _observe(to, duration, seek: true);
      return;
    }
    // Counts the time played up to the seek at the old position.
    _maxPositionS = _max(_maxPositionS, _estimatedPositionS());
    _observe(to, duration, seek: true);
    _seekCount += 1;
    _lastSeekAt = _now();
  }

  void completed({Duration? position, Duration? duration}) {
    _observe(position, duration);
    _enter(BeatState.ended);
  }

  /// An error the viewer met. Kept once per impression up to 20; a fatal one
  /// ends the impression.
  void error({
    required String code,
    String? category,
    String? message,
    bool fatal = true,
    Duration? position,
  }) {
    _observe(position, null);
    if (_errorCount < _maxErrors) {
      _pending.add(
        BeatError(
          n: _errorCount,
          code: _cut(code, 64)!,
          category: _cut(category, 32),
          message: _cut(message, 300),
          positionS: _estimatedPositionSOrNull(),
        ),
      );
    }
    _errorCount += 1;
    if (fatal) _enter(BeatState.error);
    onMilestone?.call();
  }

  /// A position report with no state change.
  void position(Duration? position, {Duration? duration}) =>
      _observe(position, duration);

  /// The counters so far, the time in the current state included.
  BeatMetrics metrics() {
    final open = _now() - _since;
    var played = _playedMs;
    var paused = _pausedMs;
    var rebuffer = _rebufferMs;
    switch (_state) {
      case BeatState.playing:
        played += open;
      case BeatState.paused:
        paused += open;
      case BeatState.buffering:
        rebuffer += open;
      default:
        break;
    }
    return BeatMetrics(
      playerStartupMs: _playerStartupMs,
      videoStartupMs: _videoStartupMs,
      playedMs: played,
      pausedMs: paused,
      rebufferMs: rebuffer,
      rebufferCount: _rebufferCount,
      seekCount: _seekCount,
      maxPositionS: _max(_maxPositionS, _estimatedPositionS()),
      durationS: _durationS,
    );
  }

  /// The errors not yet sent, once.
  List<BeatError> takeErrors() {
    final out = _pending;
    _pending = [];
    return out;
  }

  /// Errors that could not be sent go back to be sent with the next beat.
  void returnErrors(List<BeatError> errors) {
    _pending = [...errors, ..._pending].take(_maxErrors).toList();
  }

  void _enter(BeatState next) {
    if (next == _state) return;
    final now = _now();
    final spent = now - _since;
    switch (_state) {
      case BeatState.playing:
        _playedMs += spent;
        _positionS = _estimatedPositionSOrNull();
        _positionAt = now;
      case BeatState.paused:
        _pausedMs += spent;
      case BeatState.buffering:
        _rebufferMs += spent;
      default:
        break;
    }
    _maxPositionS = _max(_maxPositionS, _positionS ?? 0);
    _state = next;
    _since = now;
  }

  void _observe(Duration? position, Duration? duration, {bool seek = false}) {
    if (duration != null && duration > Duration.zero) {
      _durationS = duration.inMilliseconds / 1000;
    }
    if (position == null) return;
    final seconds = position.inMilliseconds / 1000;
    if (!seek) _maxPositionS = _max(_maxPositionS, seconds);
    _positionS = seconds;
    _positionAt = _now();
  }

  /// The players report a position only with a state change, so while
  /// playing the position is the last report plus the time since, up to the
  /// duration.
  double? _estimatedPositionSOrNull() {
    final known = _positionS;
    if (known == null) return null;
    if (_state != BeatState.playing) return known;
    final estimate = known + (_now() - _positionAt) / 1000;
    final duration = _durationS;
    return duration != null && estimate > duration ? duration : estimate;
  }

  double _estimatedPositionS() => _estimatedPositionSOrNull() ?? 0;
}

double _max(double a, double b) => a > b ? a : b;

String? _cut(String? value, int max) {
  if (value == null) return null;
  return value.length <= max ? value : value.substring(0, max);
}

MonotonicClock _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsedMilliseconds;
}
