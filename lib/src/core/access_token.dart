import 'dart:convert';

/// The DRM `access-token` header the licence servers read
/// (`/v1/drm/:stream_id/:drm/acquire`): base64 of
/// `{"headers":{"authorization":…},"parameters":{…}}`, as the web player
/// builds it in `drm.ts`.
///
/// [parameters] carries what the licence gate checks: `storefront_id`,
/// `device_id`, `playback_session_id` and `player_token`, plus any the host
/// adds (`source: internal`). Null values are left out.
String buildAccessToken(
  String authorization, {
  Map<String, Object?> parameters = const {},
}) {
  final payload = {
    'headers': {'authorization': authorization},
    'parameters': {
      for (final MapEntry(:key, :value) in parameters.entries) key: ?value,
    },
  };
  return base64Encode(utf8.encode(jsonEncode(payload)));
}
