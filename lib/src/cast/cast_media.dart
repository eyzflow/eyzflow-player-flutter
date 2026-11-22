import '../core/source.dart';

import 'cast_backend.dart';

/// What the TV plays for [source], from [startAt].
///
/// The TV takes the DASH manifest: the EYZFlow receiver plays it with
/// Widevine the way the web player does, and Google's default receiver plays
/// a clear one. Both manifests address the same segments as the HLS the
/// phones play.
///
/// [accessHeader] is the DRM `access-token` the phone plays with (null for a
/// clear stream). It carries the phone's device and playback session, so the
/// film on the TV counts as the phone's one stream.
CastMedia castMediaFor(
  EYZFlowSource source, {
  required Duration startAt,
  String? accessHeader,
}) {
  final String manifest = source.dashStreamUrl.toString();
  final Uri licence = source.widevineLicenseUrl;
  return CastMedia(
    streamId: source.id,
    contentUrl: manifest,
    contentType: 'application/dash+xml',
    title: source.title,
    posterUrl: source.poster?.toString(),
    startAt: startAt,
    customData: {
      'manifestUrl': manifest,
      if (accessHeader != null) ...{
        'licenseUrl': licence.toString(),
        'accessToken': accessHeader,
      },
    },
  );
}
