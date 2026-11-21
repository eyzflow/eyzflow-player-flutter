/// A player heartbeat ("beat") as `POST /v1/player/beat` takes it: the
/// impression's counters so far and the errors since the last beat. Same
/// schema as the web player (`analytics/types.ts`) and the backend's
/// `parseBeat`, plus `platform` for app players.
library;

/// The impression's counters so far. Cumulative, so a lost or repeated beat
/// changes nothing.
final class BeatMetrics {
  const BeatMetrics({
    this.playerStartupMs,
    this.videoStartupMs,
    this.playedMs = 0,
    this.pausedMs = 0,
    this.rebufferMs = 0,
    this.rebufferCount = 0,
    this.seekCount = 0,
    this.avgBitrate,
    this.minBitrate,
    this.maxBitrate,
    this.qualitySwitches = 0,
    this.droppedFrames = 0,
    this.maxPositionS = 0,
    this.durationS,
  });

  /// From the player starting to load to the video being ready.
  final int? playerStartupMs;

  /// From loading (the apps always autoplay) to the first frame. Null until a
  /// frame showed.
  final int? videoStartupMs;
  final int playedMs;
  final int pausedMs;
  final int rebufferMs;
  final int rebufferCount;
  final int seekCount;

  /// Bitrates and dropped frames: null and 0 in v1, because the native
  /// players do not report them yet.
  final int? avgBitrate;
  final int? minBitrate;
  final int? maxBitrate;
  final int qualitySwitches;
  final int droppedFrames;
  final double maxPositionS;
  final double? durationS;

  Map<String, Object?> toJson() => {
    'player_startup_ms': playerStartupMs,
    'video_startup_ms': videoStartupMs,
    'played_ms': playedMs,
    'paused_ms': pausedMs,
    'rebuffer_ms': rebufferMs,
    'rebuffer_count': rebufferCount,
    'seek_count': seekCount,
    'avg_bitrate': avgBitrate,
    'min_bitrate': minBitrate,
    'max_bitrate': maxBitrate,
    'quality_switches': qualitySwitches,
    'dropped_frames': droppedFrames,
    'max_position_s': maxPositionS,
    'duration_s': durationS,
  };
}

/// An error the viewer met. `n` numbers it within the impression (0–19).
final class BeatError {
  const BeatError({
    required this.n,
    required this.code,
    this.category,
    this.message,
    this.positionS,
  });

  final int n;

  /// At most 64 characters.
  final String code;

  /// At most 32 characters.
  final String? category;

  /// At most 300 characters. The backend scrubs URLs and tokens from it too.
  final String? message;
  final double? positionS;

  Map<String, Object?> toJson() => {
    'n': n,
    'code': code,
    'category': category,
    'message': message,
    'position_s': positionS,
  };
}

final class Beat {
  const Beat({
    required this.token,
    required this.sid,
    required this.seq,
    required this.startedAt,
    required this.isFinal,
    required this.streamId,
    required this.isLive,
    required this.autoplay,
    required this.drm,
    required this.playerVersion,
    required this.platform,
    required this.metrics,
    required this.errors,
  });

  /// The player token from the licence check.
  final String token;

  /// The impression id: a UUID per video loaded.
  final String sid;

  /// Grows with every beat; the server keeps the newest.
  final int seq;

  /// Wall-clock milliseconds when the impression started.
  final int startedAt;
  final bool isFinal;
  final String streamId;
  final bool isLive;
  final bool autoplay;

  /// `widevine`, `fairplay`, `playready`, `none`, or null when unknown.
  final String? drm;
  final String playerVersion;

  /// `android`, `androidtv`, `tizen`, …
  final String? platform;
  final BeatMetrics metrics;
  final List<BeatError> errors;

  Map<String, Object?> toJson() => {
    'token': token,
    'sid': sid,
    'seq': seq,
    'started_at': startedAt,
    'final': isFinal,
    'stream_id': streamId,
    'is_live': isLive,
    'autoplay': autoplay,
    'drm': drm,
    'player_version': playerVersion,
    'platform': platform,
    'm': metrics.toJson(),
    'errors': [for (final error in errors) error.toJson()],
  };
}
