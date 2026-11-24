import 'package:flutter/foundation.dart';

import 'cast_media_track.dart';

/// State pushed by the receiver (also when changed from the TV remote or
/// another sender) — listen to the session’s status stream to keep app UI
/// in sync.
@immutable
class CastSessionStatus {
  const CastSessionStatus({
    this.playerState = 'IDLE',
    this.position = Duration.zero,
    this.hasFreshPosition = true,
    this.duration,
    this.volumeLevel = 1.0,
    this.muted = false,
    List<int>? activeTrackIds,
    this.mediaTracks = const <CastMediaTrack>[],
    this.idleReason,
  }) : activeTrackIds = activeTrackIds ?? const [],
       hasActiveTrackIds = activeTrackIds != null;

  /// IDLE / BUFFERING / PLAYING / PAUSED (receiver vocabulary).
  final String playerState;
  final Duration position;
  final bool hasFreshPosition;
  final Duration? duration;

  /// Receiver volume 0..1.
  final double volumeLevel;
  final bool muted;

  /// Currently active media tracks (e.g. enabled caption track ids).
  final List<int> activeTrackIds;
  final bool hasActiveTrackIds;

  /// The loaded media's tracks, as the receiver last listed them.
  final List<CastMediaTrack> mediaTracks;

  /// FINISHED / CANCELLED / ERROR when [playerState] is IDLE.
  final String? idleReason;

  bool get isPlaying => playerState == 'PLAYING';

  CastSessionStatus copyWith({
    String? playerState,
    Duration? position,
    Duration? duration,
    double? volumeLevel,
    bool? muted,
    List<int>? activeTrackIds,
    List<CastMediaTrack>? mediaTracks,
    String? idleReason,
  }) => CastSessionStatus(
    playerState: playerState ?? this.playerState,
    position: position ?? this.position,
    hasFreshPosition: position != null,
    duration: duration ?? this.duration,
    volumeLevel: volumeLevel ?? this.volumeLevel,
    muted: muted ?? this.muted,
    activeTrackIds:
        activeTrackIds ?? (hasActiveTrackIds ? this.activeTrackIds : null),
    mediaTracks: mediaTracks ?? this.mediaTracks,
    idleReason: idleReason,
  );

  @override
  String toString() =>
      'CastSessionStatus($playerState'
      '${idleReason == null ? '' : '($idleReason)'} ${position.inSeconds}s'
      '${duration == null ? '' : '/${duration!.inSeconds}s'} '
      'vol ${(volumeLevel * 100).round()}% tracks $activeTrackIds)';
}
