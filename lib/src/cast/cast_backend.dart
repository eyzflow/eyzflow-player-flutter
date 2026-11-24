import 'dart:async';

import '../native/cast.dart' as nvp;

/// A Cast device on the network, as the picker lists it.
final class CastTarget {
  const CastTarget({
    required this.id,
    required this.name,
    this.model,
    this.raw,
  });

  final String id;
  final String name;
  final String? model;

  /// The backend's own device object.
  final Object? raw;

  @override
  bool operator ==(Object other) => other is CastTarget && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastTarget($name)';
}

/// What the TV is doing.
enum CastPlayerState { idle, buffering, playing, paused }

/// What a [CastTrack] carries.
enum CastTrackKind { audio, subtitles }

/// An audio or subtitle track of the media on the TV, as the receiver lists
/// it. [id] is the receiver's own track id, not the phone's.
final class CastTrack {
  const CastTrack({
    required this.id,
    required this.kind,
    this.language,
    this.name,
    this.roles = const [],
    this.channelCount,
  });

  static CastTrack? fromReceiver(nvp.CastMediaTrack track) {
    final kind = switch (track.type) {
      'AUDIO' => CastTrackKind.audio,
      'TEXT' => CastTrackKind.subtitles,
      _ => null,
    };
    if (kind == null) return null;
    return CastTrack(
      id: track.trackId,
      kind: kind,
      language: track.language,
      name: track.name,
      roles: track.roles,
      channelCount: track.channelCount,
    );
  }

  final int id;
  final CastTrackKind kind;
  final String? language;
  final String? name;
  final List<String> roles;
  final int? channelCount;
}

/// The receiver's state, as its last status said.
final class CastPlayback {
  const CastPlayback({
    this.state = CastPlayerState.idle,
    this.position = Duration.zero,
    this.hasFreshPosition = true,
    this.duration,
    this.idleReason,
    this.tracks = const <CastTrack>[],
    List<int>? activeTrackIds,
  }) : activeTrackIds = activeTrackIds ?? const [],
       hasActiveTrackIds = activeTrackIds != null;

  final CastPlayerState state;
  final Duration position;

  /// Whether this status includes a new media time from the receiver.
  final bool hasFreshPosition;
  final Duration? duration;

  /// The media's audio and subtitle tracks; empty until the receiver lists
  /// them.
  final List<CastTrack> tracks;

  /// The [tracks] playing now: at most one audio and one subtitle track.
  final List<int> activeTrackIds;

  /// False until the receiver explicitly reports its selection (possibly empty).
  final bool hasActiveTrackIds;

  CastPlayback atEstimatedPosition(Duration estimate) => CastPlayback(
    state: state,
    position: estimate,
    hasFreshPosition: false,
    duration: duration,
    idleReason: idleReason,
    tracks: tracks,
    activeTrackIds: hasActiveTrackIds ? activeTrackIds : null,
  );

  /// Why the receiver is idle: `FINISHED`, `CANCELLED`, `INTERRUPTED`,
  /// `ERROR`, or null.
  final String? idleReason;

  bool get isFinished =>
      state == CastPlayerState.idle && idleReason == 'FINISHED';
  bool get isError => state == CastPlayerState.idle && idleReason == 'ERROR';
}

/// What to play on the TV.
final class CastMedia {
  const CastMedia({
    required this.streamId,
    required this.contentUrl,
    required this.contentType,
    required this.title,
    this.posterUrl,
    this.startAt = Duration.zero,
    this.customData,
  });

  final String streamId;
  final String contentUrl;
  final String contentType;
  final String title;
  final String? posterUrl;
  final Duration startAt;

  /// For the EYZFlow receiver: `manifestUrl`, `licenseUrl`, `accessToken`.
  final Map<String, Object?>? customData;
}

/// One connection to a TV.
abstract interface class CastConnection {
  /// Every status the receiver pushes. Closes when the connection ends: the
  /// viewer stopped casting, the TV was switched off or another sender took
  /// over.
  Stream<CastPlayback> get playback;

  /// Requests the receiver refused (a load that failed).
  Stream<String> get errors;

  CastPlayback get current;
  Future<void> load(CastMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Plays exactly [trackIds] (audio and subtitles); a kind left out is
  /// off.
  Future<void> setActiveTracks(List<int> trackIds);

  /// Asks the receiver for a fresh status. A receiver only reports its
  /// position when its state changes, so the phone asks from time to time.
  Future<void> requestStatus();

  /// Stops the media and closes the receiver app.
  Future<void> stop();
}

/// Finds TVs and connects to them.
abstract interface class CastBackend {
  /// One scan of the local network.
  Future<List<CastTarget>> discover({Duration timeout});

  /// Connects and launches the receiver app [appId].
  Future<CastConnection> connect(CastTarget target, {required String appId});
}

/// The EYZFlow Cast receiver (`https://stream.eyzflow.com/cast/index.html`),
/// used when neither the app nor the player config names one. It adds the DRM
/// access token to licence requests, so films cast as well as trailers;
/// Google's Default Media Receiver (`CC1AD845`) plays clear streams only.
const String defaultCastReceiverAppId = 'A534F914';

/// The Chromecast client in our patched native player: CASTV2 over the local
/// network, no Google Cast SDK.
final class NativeCastBackend implements CastBackend {
  const NativeCastBackend();

  @override
  Future<List<CastTarget>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final devices = await nvp.CastDeviceDiscovery.discover(timeout: timeout);
    return [
      for (final device in devices)
        CastTarget(
          id: device.id,
          name: device.displayName,
          model: device.model,
          raw: device,
        ),
    ];
  }

  @override
  Future<CastConnection> connect(
    CastTarget target, {
    required String appId,
  }) async {
    final session = await nvp.CastSession.connect(
      target.raw! as nvp.CastDevice,
      appId: appId,
    );
    return _NativeCastConnection(session);
  }
}

final class _NativeCastConnection implements CastConnection {
  _NativeCastConnection(this._session);

  final nvp.CastSession _session;

  static CastPlayback _map(nvp.CastSessionStatus status) => CastPlayback(
    state: switch (status.playerState) {
      'PLAYING' => CastPlayerState.playing,
      'PAUSED' => CastPlayerState.paused,
      'BUFFERING' => CastPlayerState.buffering,
      _ => CastPlayerState.idle,
    },
    position: status.position,
    hasFreshPosition: status.hasFreshPosition,
    duration: status.duration,
    idleReason: status.idleReason,
    tracks: <CastTrack>[
      for (final t in status.mediaTracks) ?CastTrack.fromReceiver(t),
    ],
    activeTrackIds: status.hasActiveTrackIds ? status.activeTrackIds : null,
  );

  @override
  Stream<CastPlayback> get playback => _session.statusStream.map(_map);

  @override
  Stream<String> get errors => _session.errors;

  @override
  CastPlayback get current => _map(_session.status);

  @override
  Future<void> load(CastMedia media) => _session.loadMedia(
    contentUrl: media.contentUrl,
    contentType: media.contentType,
    title: media.title,
    imageUrl: media.posterUrl,
    startAt: media.startAt,
    customData: media.customData,
  );

  @override
  Future<void> play() => _session.play();

  @override
  Future<void> pause() => _session.pause();

  @override
  Future<void> seek(Duration position) => _session.seek(position);

  @override
  Future<void> setActiveTracks(List<int> trackIds) =>
      _session.setActiveTracks(trackIds);

  @override
  Future<void> requestStatus() => _session.requestStatus();

  @override
  Future<void> stop() async {
    try {
      await _session.stop();
    } finally {
      await _session.close();
    }
  }
}
