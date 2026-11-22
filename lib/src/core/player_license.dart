import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart';

/// Refusals of the player key check (`POST /v1/player/license`), and of DRM
/// licences by the site check. Same codes as the web player.
enum PlayerLicenseCode {
  playerKeyInvalid('PLAYER_KEY_INVALID'),
  originRequired('ORIGIN_REQUIRED'),
  playerKeyStreamMismatch('PLAYER_KEY_STREAM_MISMATCH'),
  domainNotAllowed('DOMAIN_NOT_ALLOWED'),

  /// The app is not on the key's allowed apps. Read as a refusal
  /// whether the backend answers this or [domainNotAllowed].
  appNotAllowed('APP_NOT_ALLOWED'),
  playerTokenRequired('PLAYER_TOKEN_REQUIRED'),
  playerTokenInvalid('PLAYER_TOKEN_INVALID'),
  playerTokenOriginMismatch('PLAYER_TOKEN_ORIGIN_MISMATCH');

  const PlayerLicenseCode(this.wireName);

  final String wireName;

  static PlayerLicenseCode? fromWire(Object? value) {
    for (final code in values) {
      if (code.wireName == value) return code;
    }
    return null;
  }

  /// What the viewer is told.
  String get message => switch (this) {
    PlayerLicenseCode.playerKeyInvalid =>
      'This player is not set up correctly (invalid player key).',
    PlayerLicenseCode.playerKeyStreamMismatch =>
      'This video cannot be played with this player key.',
    PlayerLicenseCode.originRequired ||
    PlayerLicenseCode.domainNotAllowed ||
    PlayerLicenseCode.appNotAllowed ||
    PlayerLicenseCode.playerTokenOriginMismatch =>
      'This video cannot be played in this app.',
    PlayerLicenseCode.playerTokenRequired ||
    PlayerLicenseCode.playerTokenInvalid =>
      "The player's licence check expired. Close the player and start again to keep watching.",
  };
}

/// A refusal of the player key check, as the host's `onLicenseError` gets it.
final class PlayerLicenseError {
  const PlayerLicenseError({required this.code, required this.message});

  factory PlayerLicenseError.of(PlayerLicenseCode code) =>
      PlayerLicenseError(code: code, message: code.message);

  final PlayerLicenseCode code;
  final String message;

  @override
  bool operator ==(Object other) =>
      other is PlayerLicenseError && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'PlayerLicenseError(${code.wireName})';
}

final class PlayerLicenseException implements Exception {
  const PlayerLicenseException(this.error);

  final PlayerLicenseError error;

  @override
  String toString() => 'PlayerLicenseException(${error.code.wireName})';
}

/// How the organisation applies the site (or app) check.
enum PlayerKeyMode {
  off,
  log,
  enforce;

  static PlayerKeyMode fromWire(Object? value) => switch (value) {
    'log' => PlayerKeyMode.log,
    'enforce' => PlayerKeyMode.enforce,
    _ => PlayerKeyMode.off,
  };
}

/// A granted player key check: the short-lived player token and what the
/// player should do with it.
final class PlayerLicense {
  const PlayerLicense({
    required this.token,
    this.expiresIn = const Duration(seconds: 900),
    this.refreshAfter = const Duration(seconds: 600),
    this.mode = PlayerKeyMode.off,
    this.wouldRefuse,
    this.analyticsEnabled = false,
    this.heartbeatInterval = const Duration(seconds: 60),
  });

  factory PlayerLicense.fromJson(Map<String, Object?> json) {
    final analytics = json['analytics'];
    final analyticsMap = analytics is Map ? analytics : const {};
    return PlayerLicense(
      token: json['token']! as String,
      expiresIn: _seconds(json['expires_in'], 900),
      refreshAfter: _seconds(json['refresh_after'], 600),
      mode: PlayerKeyMode.fromWire(json['mode']),
      wouldRefuse: PlayerLicenseCode.fromWire(json['would_refuse']),
      analyticsEnabled: analyticsMap['enabled'] == true,
      heartbeatInterval: _seconds(
        analyticsMap['heartbeat_interval_seconds'],
        60,
      ),
    );
  }

  final String token;
  final Duration expiresIn;
  final Duration refreshAfter;
  final PlayerKeyMode mode;

  /// Set when the app is not allowed but the organisation only logs: what
  /// enforce would answer. Informational.
  final PlayerLicenseCode? wouldRefuse;

  /// Whether to send beats: the key has analytics on and the app is allowed.
  final bool analyticsEnabled;
  final Duration heartbeatInterval;
}

Duration _seconds(Object? value, int fallback) =>
    Duration(seconds: value is num ? value.round() : fallback);

/// What the player key check is asked about.
final class PlayerLicenseRequest {
  const PlayerLicenseRequest({
    required this.key,
    required this.streamId,
    this.configId,
    this.app,
    this.playerVersion = eyzflowPlayerVersion,
  });

  /// `pk_…`, from the dashboard's Player → Keys.
  final String key;
  final String streamId;
  final String? configId;

  /// The app in place of a web Origin. Without it the backend answers
  /// `ORIGIN_REQUIRED` to a native client.
  final PlayerApp? app;
  final String playerVersion;

  Map<String, Object?> toJson() => {
    'key': key,
    'stream_id': streamId,
    'config_id': ?configId,
    'player_version': playerVersion,
    if (app != null) 'app': app!.toJson(),
  };
}

/// `POST /v1/player/license`.
final class PlayerLicenseClient {
  PlayerLicenseClient({
    http.Client? client,
    this.endpoints = const EYZFlowEndpoints(),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final EYZFlowEndpoints endpoints;

  /// Throws [PlayerLicenseException] on a refusal, and any other exception
  /// when the check could not be made (network, server error, rate limit).
  Future<PlayerLicense> acquire(PlayerLicenseRequest request) async {
    final response = await _client.post(
      endpoints.apiUri('/v1/player/license'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(request.toJson()),
    );
    final Object? body = _decode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = body is Map
          ? PlayerLicenseCode.fromWire(body['code'])
          : null;
      if (code != null) {
        throw PlayerLicenseException(PlayerLicenseError.of(code));
      }
      throw http.ClientException(
        'Player licence check failed (${response.statusCode}).',
        response.request?.url,
      );
    }
    if (body is! Map<String, Object?> || body['token'] is! String) {
      throw const FormatException('Player licence answer has no token.');
    }
    return PlayerLicense.fromJson(body);
  }

  void close() => _client.close();
}

Object? _decode(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return null;
  }
}

typedef PlayerLicenseAcquirer =
    Future<PlayerLicense> Function(PlayerLicenseRequest request);

/// The current player token, renewed before it expires while the player is
/// open. A failed renewal keeps the old token and tries again a minute later;
/// a refusal (the key was switched off, the app removed) is reported once.
final class PlayerLicenseSession {
  PlayerLicenseSession._(
    this._request,
    this._current,
    this._acquire,
    this._onRefused,
  ) {
    _schedule(_current.refreshAfter);
  }

  /// Makes the first check. Throws as [PlayerLicenseClient.acquire] does.
  static Future<PlayerLicenseSession> start(
    PlayerLicenseRequest request, {
    required PlayerLicenseAcquirer acquire,
    required void Function(PlayerLicenseError error) onRefused,
  }) async {
    final first = await acquire(request);
    return PlayerLicenseSession._(request, first, acquire, onRefused);
  }

  final PlayerLicenseRequest _request;
  final PlayerLicenseAcquirer _acquire;
  final void Function(PlayerLicenseError error) _onRefused;
  PlayerLicense _current;
  Timer? _timer;
  var _stopped = false;

  PlayerLicense get current => _current;
  String get token => _current.token;

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration after) {
    if (_stopped) return;
    const floor = Duration(seconds: 10);
    _timer = Timer(after < floor ? floor : after, _refresh);
  }

  Future<void> _refresh() async {
    try {
      final next = await _acquire(_request);
      if (_stopped) return;
      _current = next;
      _schedule(next.refreshAfter);
    } on PlayerLicenseException catch (refusal) {
      if (_stopped) return;
      stop();
      _onRefused(refusal.error);
    } on Object {
      _schedule(const Duration(seconds: 60));
    }
  }
}
