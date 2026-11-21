import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';

/// Refusals the backend gives when a plan's stream or device limit is
/// reached, or the viewer was signed out. Same codes as the web player.
enum PlaybackLimitCode {
  streamLimit('STREAM_LIMIT'),
  deviceLimit('DEVICE_LIMIT'),
  deviceRevoked('DEVICE_REVOKED'),
  sessionRevoked('SESSION_REVOKED'),

  /// Not a backend code: the heartbeat found the session ended elsewhere.
  playbackSessionEnded('PLAYBACK_SESSION_ENDED');

  const PlaybackLimitCode(this.wireName);

  final String wireName;

  static PlaybackLimitCode? fromWire(Object? value) {
    for (final code in values) {
      if (code.wireName == value) return code;
    }
    return null;
  }

  /// What the viewer is told.
  String get message => switch (this) {
    PlaybackLimitCode.streamLimit =>
      "You're watching on too many screens. Stop playback on another device to watch here.",
    PlaybackLimitCode.deviceLimit =>
      "Your plan's device limit is reached. Remove a device in your account to watch here.",
    PlaybackLimitCode.deviceRevoked || PlaybackLimitCode.sessionRevoked =>
      'You were signed out on this device. Sign in again to watch.',
    PlaybackLimitCode.playbackSessionEnded =>
      'Playback was stopped from another device.',
  };
}

/// A limit refusal, as the host's `onLimitReached` gets it.
final class PlaybackLimitError {
  const PlaybackLimitError({
    required this.code,
    required this.message,
    this.details = const {},
  });

  final PlaybackLimitCode code;

  /// The viewer-facing text for [code] (not the server's wording).
  final String message;

  /// The response body: `sessions` for STREAM_LIMIT, `devices` for
  /// DEVICE_LIMIT. Empty when the refusal did not come from a response.
  final Map<String, Object?> details;

  @override
  String toString() => 'PlaybackLimitError(${code.wireName})';
}

final class PlaybackLimitException implements Exception {
  const PlaybackLimitException(this.error);

  final PlaybackLimitError error;

  @override
  String toString() => 'PlaybackLimitException(${error.code.wireName})';
}

/// An open playback session.
final class PlaybackSession {
  const PlaybackSession({
    required this.id,
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  /// Null while the storefront's limits are off: nothing to heartbeat or close.
  final String? id;
  final Duration heartbeatInterval;
}

/// Whose session it is: the storefront, the viewer and their device.
final class PlaybackSessionTarget {
  const PlaybackSessionTarget({
    required this.storefrontId,
    required this.authorization,
    required this.deviceId,
  });

  final String storefrontId;

  /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
  final String authorization;
  final String deviceId;
}

/// Reads a limit refusal from a response body, if it is one.
PlaybackLimitError? readLimitError(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final code = PlaybackLimitCode.fromWire(decoded['code']);
  if (code == null) return null;
  return PlaybackLimitError(
    code: code,
    message: code.message,
    details: decoded,
  );
}

/// Concurrent-stream and device limits:
/// `/v1/content/storefront/:storefront_id/playback-sessions`.
final class PlaybackSessionClient {
  PlaybackSessionClient({
    http.Client? client,
    this.endpoints = const EyzflowEndpoints(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final EyzflowEndpoints endpoints;

  Uri _url(String storefrontId, [String path = '']) => endpoints.apiUri(
    '/v1/content/storefront/${Uri.encodeComponent(storefrontId)}'
    '/playback-sessions$path',
  );

  Map<String, String> _headers(PlaybackSessionTarget target) => {
    'Content-Type': 'application/json',
    'Authorization': target.authorization,
    'X-Device-Id': target.deviceId,
  };

  /// Starts watching: checks the plan's limits. Throws
  /// [PlaybackLimitException] on a limit, and any other exception when the
  /// session could not be opened.
  Future<PlaybackSession> open(
    PlaybackSessionTarget target, {
    required String streamId,
    required PlayerPlatform platform,
    String? deviceName,
  }) async {
    final response = await _client.post(
      _url(target.storefrontId),
      headers: _headers(target),
      body: jsonEncode({
        'stream_id': streamId,
        'platform': platform.wireName,
        'device_name': ?deviceName,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final limit = readLimitError(response.body);
      if (limit != null) throw PlaybackLimitException(limit);
      throw http.ClientException(
        'Could not start playback (${response.statusCode}).',
        response.request?.url,
      );
    }
    final Object? body = jsonDecode(response.body);
    final map = body is Map ? body : const {};
    final Object? id = map['id'];
    final Object? interval = map['heartbeat_interval_seconds'];
    return PlaybackSession(
      id: id is String && id.isNotEmpty ? id : null,
      heartbeatInterval: Duration(
        seconds: interval is num && interval > 0 ? interval.round() : 30,
      ),
    );
  }

  /// Keeps the session open. False when it was ended elsewhere (device
  /// removed, signed out everywhere); true on a passing failure, so the next
  /// heartbeat tries again.
  Future<bool> heartbeat(PlaybackSessionTarget target, String sessionId) async {
    final http.Response response;
    try {
      response = await _client.post(
        _url(
          target.storefrontId,
          '/${Uri.encodeComponent(sessionId)}/heartbeat',
        ),
        headers: _headers(target),
      );
    } on Object {
      return true;
    }
    if (response.statusCode == 401 || response.statusCode == 404) return false;
    if (response.statusCode < 200 || response.statusCode >= 300) return true;
    try {
      final Object? body = jsonDecode(response.body);
      return !(body is Map && body['status'] == 'ended');
    } on FormatException {
      return true;
    }
  }

  /// Stops watching so the stream is free at once. Never throws.
  Future<void> close(PlaybackSessionTarget target, String sessionId) async {
    try {
      await _client.delete(
        _url(target.storefrontId, '/${Uri.encodeComponent(sessionId)}'),
        headers: _headers(target),
      );
    } on Object {
      // The server drops a session that stops heartbeating.
    }
  }

  void dispose() => _client.close();
}
