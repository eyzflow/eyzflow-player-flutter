/// Where the player's EYZFlow calls go, and what it says it is.
library;

/// The EYZFlow origins the player talks to. Production by default; a host
/// points them at a dev or staging stack for testing.
final class EyzflowEndpoints {
  const EyzflowEndpoints({
    this.api = 'https://api.eyzflow.com',
    this.streamCdn = 'https://stream.eyzflow.com',
  });

  /// DRM licences, playback sessions, player keys and analytics.
  final String api;

  /// Manifests, segments and the FairPlay certificate. Kept for parity with
  /// the web player; the player builds its stream URLs from `EyzflowSource`.
  final String streamCdn;

  Uri apiUri(String path) => Uri.parse('${_trim(api)}$path');

  static String _trim(String origin) =>
      origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
}

/// This library's version, sent with licence checks and beats. Prefixed so
/// the backend can tell app players from the web player (`0.2.0`).
const String eyzflowPlayerVersion = 'flutter/0.2.0';

/// Where the player runs, as playback sessions, licence checks and beats name
/// it. The wire values are the backend's (`playback-sessions.controller.ts`).
enum PlayerPlatform {
  android('android'),
  androidTv('androidtv'),
  ios('ios'),
  tvos('tvos'),
  tizen('tizen'),
  webos('webos');

  const PlayerPlatform(this.wireName);

  final String wireName;

  /// TV platforms, for the analytics device class.
  bool get isTv => switch (this) {
    PlayerPlatform.androidTv ||
    PlayerPlatform.tvos ||
    PlayerPlatform.tizen ||
    PlayerPlatform.webos => true,
    PlayerPlatform.android || PlayerPlatform.ios => false,
  };

  /// The DRM system the platform's player uses for protected streams, as
  /// beats name it: Widevine on Android and Tizen, FairPlay on Apple.
  String get drmName => switch (this) {
    PlayerPlatform.ios || PlayerPlatform.tvos => 'fairplay',
    PlayerPlatform.webos => 'playready',
    _ => 'widevine',
  };
}

/// The app the player runs in, sent with the player key check in place of a
/// web page's Origin: the platform and the app's package name or bundle id.
final class PlayerApp {
  const PlayerApp({required this.platform, required this.id});

  final PlayerPlatform platform;

  /// `com.example.app`.
  final String id;

  Map<String, Object?> toJson() => {'platform': platform.wireName, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is PlayerApp && other.platform == platform && other.id == id;

  @override
  int get hashCode => Object.hash(platform, id);

  @override
  String toString() => 'PlayerApp(${platform.wireName}, $id)';
}
