import '../../models/cast_device.dart';
import 'cast_session_status.dart';

export 'cast_session_status.dart';

/// Web/WASM stubs: CASTV2 needs dart:io sockets. The API mirrors the io
/// implementation so shared code compiles; everything network-touching
/// throws [UnsupportedError].
class CastTextTrack {
  const CastTextTrack({
    required this.trackId,
    required this.url,
    required this.language,
    this.name,
    this.contentType = 'text/vtt',
  });

  final int trackId;
  final String url;
  final String language;
  final String? name;
  final String contentType;
}

class CastSession {
  CastSession._(this.device);

  final CastDevice device;

  static Never _unsupported() => throw UnsupportedError(
    'CastSession is not supported on this platform (requires dart:io).',
  );

  static const String defaultReceiverAppId = 'CC1AD845';

  String get appId => _unsupported();

  static Future<CastSession> connect(
    CastDevice device, {
    Duration timeout = const Duration(seconds: 10),
    String appId = defaultReceiverAppId,
  }) => _unsupported();

  Stream<String> get errors => _unsupported();

  Stream<CastSessionStatus> get statusStream => _unsupported();

  CastSessionStatus get status => _unsupported();

  bool get isConnected => false;

  Future<void> loadMedia({
    required String contentUrl,
    String contentType = 'video/mp4',
    String streamType = 'BUFFERED',
    String? title,
    String? subtitle,
    String? imageUrl,
    List<CastTextTrack> textTracks = const <CastTextTrack>[],
    List<int> activeTrackIds = const <int>[],
    bool autoplay = true,
    Duration startAt = Duration.zero,
    Map<String, dynamic>? customData,
  }) => _unsupported();

  Future<void> play() => _unsupported();

  Future<void> pause() => _unsupported();

  Future<void> stop() => _unsupported();

  Future<void> seek(Duration position) => _unsupported();

  Future<void> setVolume(double level) => _unsupported();

  Future<void> setMuted(bool muted) => _unsupported();

  Future<void> setActiveTracks(List<int> trackIds) => _unsupported();

  // ignore: avoid_positional_boolean_parameters
  void setLooping(bool looping) => _unsupported();

  Future<void> requestStatus() => _unsupported();

  Future<void> close() => _unsupported();
}
