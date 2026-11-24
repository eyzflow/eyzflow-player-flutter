import 'package:flutter/foundation.dart';

/// A track the receiver reports for the loaded media (`media.tracks` in its
/// status): the stream's own audio and subtitle tracks as well as sidecar
/// text tracks. Its [trackId] is what `EDIT_TRACKS_INFO` selects.
@immutable
class CastMediaTrack {
  const CastMediaTrack({
    required this.trackId,
    required this.type,
    this.language,
    this.name,
    this.roles = const [],
    this.channelCount,
  });

  final int trackId;

  /// `AUDIO`, `TEXT` or `VIDEO` (receiver vocabulary).
  final String type;
  final String? language;
  final String? name;
  final List<String> roles;
  final int? channelCount;
}

/// The tracks in a receiver status's `media`, or null when the status
/// carries no track list (most pushes only carry what changed).
List<CastMediaTrack>? castMediaTracks(Map<String, dynamic>? media) {
  final List<Object?>? tracks = media?['tracks'] as List<Object?>?;
  if (tracks == null) return null;
  return <CastMediaTrack>[
    for (final Object? t in tracks)
      if (t is Map && t['trackId'] is num && t['type'] is String)
        CastMediaTrack(
          trackId: (t['trackId'] as num).toInt(),
          type: t['type'] as String,
          language: t['language'] as String?,
          name: t['name'] as String?,
          roles: switch (t['roles']) {
            final List roles => roles.whereType<String>().toList(),
            _ => const [],
          },
          channelCount: switch (t['audioTrackInfo']) {
            {'numAudioChannels': final int count} when count > 0 => count,
            _ => null,
          },
        ),
  ];
}
