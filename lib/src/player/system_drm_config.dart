import '../core/source.dart';

import 'playback_target.dart';

/// Widevine (Android) or FairPlay (iOS) configuration for a source-backed
/// target that carries a DRM credential, and nothing for a trailer or an
/// unprotected source.
///
/// A trailer target is never DRM-protected — that's what its type already
/// says, mirroring `drmConfigsForTarget` in `tizen_avplay_player.dart`. The
/// access token travels as the same `access-token` header
/// `WidevineLicenseClient` already sends on Tizen; unlike AVPlay,
/// the native player can attach it to its own licence request
/// directly, so this needs no Dart-side licence-fetch callback.
Map<String, dynamic>? systemDrmConfigForTarget(
  VideoplayerTarget target, {
  required bool isIOS,
}) {
  final EyzflowSource? source = switch (target) {
    VideoplayerTrailerTarget() => null,
    VideoplayerSourceTarget(:final source) => source,
  };
  final String? accessHeader = source?.drmAccessHeader;
  if (source == null || accessHeader == null) return null;

  final Map<String, String> headers = <String, String>{
    'access-token': accessHeader,
  };

  if (isIOS) {
    return <String, dynamic>{
      'type': 'fairplay',
      'certificateUrl': source.fairplayCertificateUrl.toString(),
      'licenseUrl': source.fairplayLicenseUrl.toString(),
      'headers': headers,
    };
  }

  return <String, dynamic>{
    'type': 'widevine',
    'licenseUrl': source.widevineLicenseUrl.toString(),
    'headers': headers,
  };
}
