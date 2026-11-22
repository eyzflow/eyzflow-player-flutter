import 'playback_event.dart';
import 'player_log.dart';
import 'player_policy.dart';

/// Turns what one player reports into [PlaybackEvent]s.
///
/// Most events are read off the controller's ticks by comparing each
/// [VideoplaybackValue] with the one before it ([tick]). What a tick cannot
/// show is told to it outright: [ready], [seeked], [audioTrackChanged],
/// [subtitleTrackChanged], [error] and [close].
///
/// Pure Dart on purpose — no plugin type, no widget, no timer — so the rules
/// below are tested without a player:
///
/// * [PlaybackStarted] is reported once, on the first tick that is playing
///   and not stalled. Nothing before it is a pause, a stall or an inferred
///   seek: the resume seek and the wait for the first frame are startup.
/// * [PlaybackPaused] and [PlaybackResumed] follow
///   [VideoplaybackValue.isPaused] and [VideoplaybackValue.isPlaying]. A
///   stall is [PlaybackBufferingStarted] and [PlaybackBufferingEnded] and
///   never a pause, whichever way the native player spells it.
/// * Each distinct error message is reported once.
/// * [PlaybackCompleted] is reported once, and after it ticks report nothing:
///   both native players pause and seek on their own when a film ends.
/// * [PlaybackClosed] is reported once and nothing follows it.
///
/// Track changes made in the phone's native controls are not observable from
/// Dart and are therefore never reported; seeks made there are inferred from
/// the position (see [seekJumpThreshold]).
final class PlaybackEventEmitter {
  PlaybackEventEmitter({
    required this.sourceId,
    required this.onEvent,
    Duration Function()? clock,
    this.seekJumpThreshold = const Duration(seconds: 3),
    this.explicitSeekGrace = const Duration(seconds: 10),
  }) : _clock = clock ?? _monotonicClock();

  /// `EyzflowSource.id`, stamped on every event.
  final String sourceId;

  /// Where events go. While this is `null` the emitter does nothing at all —
  /// no event, no bookkeeping — so a host that passes no callback gets the
  /// player exactly as it was. Assignable because a host rebuilding its view
  /// hands over a new closure, and the sequence must carry on into it.
  PlaybackEventCallback? onEvent;

  /// How far the position must move beyond what playing could explain before
  /// a tick counts as a seek. On phones the native controls seek without
  /// telling Dart, so a jump is the only evidence there is. Backwards, any
  /// move larger than this is a seek. Forwards, unless playback is paused,
  /// the wall-clock time since the previous tick is allowed for first — twice
  /// over, for a viewer watching at double speed — because ticks stop while
  /// the app is hidden and picture-in-picture keeps playing. A few seconds,
  /// so that the small corrections a player makes around a stall are not
  /// seeks; the cost is that a scrub shorter than this goes unreported.
  final Duration seekJumpThreshold;

  /// How long after [seeked] a position jump is taken to be that same seek
  /// landing rather than a second one. Generous, because a TV on a slow
  /// network can take seconds to land, and nothing else seeks a player that
  /// is driven by the overlay.
  final Duration explicitSeekGrace;

  /// Monotonic time. Injected so the seek rules can be tested without
  /// waiting.
  final Duration Function() _clock;

  /// A pause this close to the end is the player winding down, not the
  /// viewer: AVPlay pauses itself a moment before it reports completion.
  static const Duration _endSlack = Duration(seconds: 2);

  /// The fastest rate the native controls offer.
  static const int _fastestPlaybackRate = 2;

  Duration? _position;
  Duration? _positionAt;
  Duration? _duration;
  Duration? _explicitSeekAt;
  final Set<String> _reportedErrors = <String>{};
  var _readyReported = false;
  var _started = false;
  var _paused = false;
  var _buffering = false;
  var _completed = false;
  var _closed = false;
  var _inAdBreak = false;

  /// False from [PlaybackStarted] until the position first moves. AVPlay
  /// notifies "playing" before it has polled a position, so a resumed film
  /// reports zero and then its resume position; that first move is where
  /// playback is, not a seek.
  var _positionSettled = false;

  bool get _isSilent => onEvent == null || _closed;

  Duration get _at => _position ?? Duration.zero;

  /// One native tick.
  void tick(VideoplaybackValue value) {
    if (_isSilent || _completed) return;

    final Duration? duration = value.duration;
    if (duration != null && duration > Duration.zero) _duration = duration;
    final Duration? position = value.position;
    if (position != null) {
      final Duration now = _clock();
      // Wherever the tick that ends the film puts the position, the film got
      // there by playing.
      if (!value.isCompleted) _reportSeekIfJumped(position, now);
      _position = position;
      _positionAt = now;
    }

    final String? errorMessage = value.errorMessage;
    if (errorMessage != null) error(errorMessage);

    if (value.isCompleted) {
      _completed = true;
      _emit(
        PlaybackCompleted(
          sourceId: sourceId,
          position: _at,
          duration: _duration,
        ),
      );
      return;
    }

    if (!_started) {
      // AVPlay reports "playing" from the moment play is requested, so a
      // stalled start is not a start yet.
      if (!value.isPlaying || value.isBuffering) return;
      // A controller that plays without ever reporting it initialized has
      // initialized all the same, and a host timing startup needs both ends.
      ready();
      _started = true;
      _emit(
        PlaybackStarted(sourceId: sourceId, position: _at, duration: _duration),
      );
      return;
    }

    if (value.isBuffering != _buffering) {
      _buffering = value.isBuffering;
      _emit(
        _buffering
            ? PlaybackBufferingStarted(
                sourceId: sourceId,
                position: _at,
                duration: _duration,
              )
            : PlaybackBufferingEnded(
                sourceId: sourceId,
                position: _at,
                duration: _duration,
              ),
      );
    }

    if (value.isPlaying) {
      if (!_paused) return;
      _paused = false;
      _emit(
        PlaybackResumed(sourceId: sourceId, position: _at, duration: _duration),
      );
    } else if (value.isPaused && !_paused && !_isAtEnd) {
      _paused = true;
      _emit(
        PlaybackPaused(sourceId: sourceId, position: _at, duration: _duration),
      );
    }
  }

  /// The player initialized. [position] and [duration] are what it knew at
  /// that moment, for a controller that has not ticked yet.
  void ready({Duration? position, Duration? duration}) {
    if (_isSilent || _readyReported) return;
    _readyReported = true;
    _position ??= position;
    if (duration != null && duration > Duration.zero) _duration ??= duration;
    _emit(
      PlaybackReady(sourceId: sourceId, position: _at, duration: _duration),
    );
  }

  /// A seek the overlay issued, from [from] to [to].
  ///
  /// The position jump that follows is this seek landing, so [tick] does not
  /// report it again (see [explicitSeekGrace]).
  void seeked(Duration from, Duration to) {
    if (_isSilent) return;
    final Duration now = _clock();
    _explicitSeekAt = now;
    _position = to;
    _positionAt = now;
    _emit(
      PlaybackSeeked(
        sourceId: sourceId,
        from: from,
        position: to,
        duration: _duration,
      ),
    );
  }

  /// The viewer switched audio track in the overlay.
  void audioTrackChanged(String? language) {
    if (_isSilent) return;
    _emit(
      PlaybackAudioTrackChanged(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
        language: language,
      ),
    );
  }

  /// The viewer switched subtitle track in the overlay; `null` is off.
  void subtitleTrackChanged(String? language) {
    if (_isSilent) return;
    _emit(
      PlaybackSubtitleTrackChanged(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
        language: language,
      ),
    );
  }

  /// An ad break began. Reported once per break, also for one that turns
  /// out to have no ad.
  void adBreakStarted() {
    if (_isSilent || _inAdBreak) return;
    _inAdBreak = true;
    _emit(
      PlaybackAdBreakStarted(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
      ),
    );
  }

  /// The ad break is over.
  void adBreakEnded() {
    if (_isSilent || !_inAdBreak) return;
    _inAdBreak = false;
    _emit(
      PlaybackAdBreakEnded(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
      ),
    );
  }

  /// Playback entered [signal].
  void signalStarted(StreamSignal signal) {
    if (_isSilent) return;
    _emit(
      PlaybackSignalStarted(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
        signal: signal,
      ),
    );
  }

  /// Playback left [signal].
  void signalEnded(StreamSignal signal) {
    if (_isSilent) return;
    _emit(
      PlaybackSignalEnded(
        sourceId: sourceId,
        position: _at,
        duration: _duration,
        signal: signal,
      ),
    );
  }

  /// A failure, from a tick or from startup — a timeout or a load that threw
  /// never shows up in a tick. The same message is reported once however
  /// often, and by whichever route, it arrives.
  void error(String message) {
    if (_isSilent || !_reportedErrors.add(message)) return;
    _emit(
      PlaybackError(
        sourceId: sourceId,
        message: message,
        position: _at,
        duration: _duration,
      ),
    );
  }

  /// The player is gone. Everything after this is ignored.
  void close() {
    if (_closed) return;
    if (onEvent != null) {
      _emit(
        PlaybackClosed(sourceId: sourceId, position: _at, duration: _duration),
      );
    }
    _closed = true;
  }

  bool get _isAtEnd {
    final Duration? position = _position;
    final Duration? duration = _duration;
    return position != null &&
        duration != null &&
        duration - position <= _endSlack;
  }

  void _reportSeekIfJumped(Duration position, Duration now) {
    final Duration? previous = _position;
    final Duration? previousAt = _positionAt;
    if (!_started ||
        previous == null ||
        previousAt == null ||
        position == previous) {
      return;
    }
    if (!_positionSettled) {
      _positionSettled = true;
      return;
    }
    final Duration moved = position - previous;
    // A paused player goes nowhere by itself, however long it sat there.
    final Duration playable = _paused
        ? Duration.zero
        : (now - previousAt) * _fastestPlaybackRate;
    if (moved >= -seekJumpThreshold && moved <= playable + seekJumpThreshold) {
      return;
    }
    final Duration? explicitSeekAt = _explicitSeekAt;
    if (explicitSeekAt != null && now - explicitSeekAt <= explicitSeekGrace) {
      return;
    }
    _emit(
      PlaybackSeeked(
        sourceId: sourceId,
        from: previous,
        position: position,
        duration: _duration,
      ),
    );
  }

  void _emit(PlaybackEvent event) {
    try {
      onEvent?.call(event);
    } on Object catch (error) {
      // Analytics is best-effort, like watch progress: a host callback that
      // throws must not take the player's own listeners down with it.
      logPlayback('playback event callback failed', error: error);
    }
  }
}

Duration Function() _monotonicClock() {
  final Stopwatch stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}
