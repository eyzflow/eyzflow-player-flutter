import 'package:equatable/equatable.dart';

/// Receives every [PlaybackEvent] of one player.
///
/// Called synchronously from the player's own listeners, so it must be cheap
/// and must not throw; a throw is logged and swallowed rather than allowed to
/// interrupt playback.
typedef PlaybackEventCallback = void Function(PlaybackEvent event);

/// Something playback did, for the host to map onto whatever analytics tool
/// it uses. This package imports no analytics SDK.
///
/// One player instance reports one sequence: [PlaybackReady], then
/// [PlaybackStarted] once, then whatever the viewer and the network do, and
/// [PlaybackClosed] last. A player that fails before it initializes reports
/// only [PlaybackError] and [PlaybackClosed]. A retry after a failure, or a
/// change of source, is a new player and so a new sequence.
///
/// Sealed, so a host's `switch` over the subclasses is checked for
/// exhaustiveness when an event is added.
sealed class PlaybackEvent extends Equatable {
  const PlaybackEvent({
    required this.sourceId,
    required this.position,
    this.duration,
  });

  /// `EyzflowSource.id` of the stream being played.
  final String sourceId;

  /// The playback position when it happened. [Duration.zero] until the native
  /// player has reported one.
  final Duration position;

  /// Total length, or `null` until the native player has resolved it.
  final Duration? duration;

  /// Spelled out per subclass rather than read from `runtimeType`, which an
  /// obfuscated release build renames.
  String get _name;

  /// The subclass's own fields, for [toString].
  Map<String, Object?> get _details => const <String, Object?>{};

  @override
  List<Object?> get props => <Object?>[sourceId, position, duration];

  @override
  String toString() {
    final Duration? duration = this.duration;
    final List<String> fields = <String>[
      'sourceId: $sourceId',
      'position: ${_clock(position)}',
      if (duration != null) 'duration: ${_clock(duration)}',
      for (final MapEntry<String, Object?> detail in _details.entries)
        '${detail.key}: ${detail.value}',
    ];
    return '$_name(${fields.join(', ')})';
  }
}

/// `h:mm:ss`, dropping the microseconds [Duration.toString] carries: a log
/// line is read by a person.
String _clock(Duration value) => value.toString().split('.').first;

/// The native player initialized, before the first frame. The time from here
/// to [PlaybackStarted] is the startup wait the viewer sat through.
final class PlaybackReady extends PlaybackEvent {
  const PlaybackReady({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackReady';
}

/// Reported once: the first time the native player reports it is playing.
final class PlaybackStarted extends PlaybackEvent {
  const PlaybackStarted({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackStarted';
}

/// Playback was paused, by the viewer or by the system (screen off, app
/// hidden). A stall is [PlaybackBufferingStarted], never this.
final class PlaybackPaused extends PlaybackEvent {
  const PlaybackPaused({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackPaused';
}

/// Playback continued after a [PlaybackPaused].
final class PlaybackResumed extends PlaybackEvent {
  const PlaybackResumed({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackResumed';
}

/// The position was moved: a skip, a scrub, or a seek in the native controls.
/// [position] is where it landed.
///
/// A seek made through the TV overlay is reported when it is issued, with the
/// requested target as [position]. A seek made in the phone's native controls
/// is inferred from the position jumping, so one shorter than a few seconds
/// goes unreported.
final class PlaybackSeeked extends PlaybackEvent {
  const PlaybackSeeked({
    required super.sourceId,
    required this.from,
    required super.position,
    super.duration,
  });

  /// Where playback was before the seek.
  final Duration from;

  @override
  String get _name => 'PlaybackSeeked';

  @override
  Map<String, Object?> get _details => <String, Object?>{'from': _clock(from)};

  @override
  List<Object?> get props => <Object?>[...super.props, from];
}

/// Playback stalled to fill its buffer. Only reported after
/// [PlaybackStarted]: the wait before the first frame is startup, not a
/// rebuffer.
final class PlaybackBufferingStarted extends PlaybackEvent {
  const PlaybackBufferingStarted({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackBufferingStarted';
}

/// The stall reported by [PlaybackBufferingStarted] is over.
final class PlaybackBufferingEnded extends PlaybackEvent {
  const PlaybackBufferingEnded({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackBufferingEnded';
}

/// Playback failed. Each distinct [message] is reported once per player, even
/// though the native player repeats it on every tick.
final class PlaybackError extends PlaybackEvent {
  const PlaybackError({
    required super.sourceId,
    required this.message,
    required super.position,
    super.duration,
  });

  /// The text the failure alert shows the viewer.
  final String message;

  @override
  String get _name => 'PlaybackError';

  @override
  Map<String, Object?> get _details => <String, Object?>{'message': message};

  @override
  List<Object?> get props => <Object?>[...super.props, message];
}

/// The viewer switched audio track in the TV overlay.
///
/// A switch made in the phone's native controls is not reported: the native
/// player does not tell Dart about it.
final class PlaybackAudioTrackChanged extends PlaybackEvent {
  const PlaybackAudioTrackChanged({
    required super.sourceId,
    required super.position,
    super.duration,
    this.language,
  });

  /// The new track's language tag as the stream carries it (`de`, `deu`,
  /// `de_DE`), or `null` when the track names none.
  final String? language;

  @override
  String get _name => 'PlaybackAudioTrackChanged';

  @override
  Map<String, Object?> get _details => <String, Object?>{'language': language};

  @override
  List<Object?> get props => <Object?>[...super.props, language];
}

/// The viewer switched subtitle track, or turned subtitles off, in the TV
/// overlay.
///
/// A switch made in the phone's native controls is not reported: the native
/// player does not tell Dart about it. Neither is the track the player picks
/// on its own when a film opens, including a remembered language.
final class PlaybackSubtitleTrackChanged extends PlaybackEvent {
  const PlaybackSubtitleTrackChanged({
    required super.sourceId,
    required super.position,
    super.duration,
    this.language,
  });

  /// The new track's language tag as the stream carries it, or `null` when
  /// subtitles were turned off.
  final String? language;

  @override
  String get _name => 'PlaybackSubtitleTrackChanged';

  @override
  Map<String, Object?> get _details => <String, Object?>{'language': language};

  @override
  List<Object?> get props => <Object?>[...super.props, language];
}

/// An ad break began: the content stopped (or has not started yet) while an
/// ad from the player config's ad tag is requested and played. Everything the
/// content reports until [PlaybackAdBreakEnded] (its pause, its resume) is
/// the ad break's doing, not the viewer's.
final class PlaybackAdBreakStarted extends PlaybackEvent {
  const PlaybackAdBreakStarted({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackAdBreakStarted';
}

/// The ad break is over: played, empty, failed or timed out. The content
/// plays on.
final class PlaybackAdBreakEnded extends PlaybackEvent {
  const PlaybackAdBreakEnded({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackAdBreakEnded';
}

/// Playback reached the end. Reported once; only [PlaybackClosed] follows.
final class PlaybackCompleted extends PlaybackEvent {
  const PlaybackCompleted({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackCompleted';
}

/// The player was disposed. Reported once and always last, whether playback
/// completed, failed, or the viewer left; [position] is the last one the
/// native player reported.
final class PlaybackClosed extends PlaybackEvent {
  const PlaybackClosed({
    required super.sourceId,
    required super.position,
    super.duration,
  });

  @override
  String get _name => 'PlaybackClosed';
}
