import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/language_names.dart';
import 'cast_backend.dart';

/// Where casting is.
sealed class CastState {
  const CastState();
}

/// Not casting: the phone plays.
final class CastOff extends CastState {
  const CastOff();
}

/// Connecting to [target] and loading the media.
final class CastConnecting extends CastState {
  const CastConnecting(this.target);

  final CastTarget target;
}

/// The TV plays.
final class CastActive extends CastState {
  const CastActive(this.target, this.playback);

  final CastTarget target;
  final CastPlayback playback;
}

/// Casting to [target] failed; the phone plays again.
final class CastFailed extends CastState {
  const CastFailed(this.target, this.reason);

  final CastTarget target;
  final String reason;
}

/// Why casting ended, with where the TV was.
enum CastEndReason {
  /// The viewer pressed Stop casting.
  stopped,

  /// The film played to its end on the TV.
  finished,

  /// The TV closed the connection: switched off, another phone took over,
  /// or the receiver app was stopped from the TV.
  disconnected,

  /// The receiver could not play the media.
  failed,
}

typedef CastEnded = void Function(CastEndReason reason, Duration position);

/// Finds TVs, casts one film to one of them and reports how it ends.
///
/// The player shows a Cast button once [devices] is not empty, hands playback
/// to the TV with [cast], and takes it back on [onEnded] at the TV's
/// position.
final class EYZFlowCastController extends ChangeNotifier {
  EYZFlowCastController({
    this._backend = const NativeCastBackend(),
    this.onPlayback,
    this.onEnded,
    this.loadTimeout = const Duration(seconds: 20),
  });

  final CastBackend _backend;

  /// Every status the TV reports while casting.
  final ValueChanged<CastPlayback>? onPlayback;
  final CastEnded? onEnded;

  /// How long the TV may take to start playing before casting counts as
  /// failed.
  final Duration loadTimeout;

  List<CastTarget> _devices = const [];
  var _scanning = false;
  CastState _state = const CastOff();
  CastConnection? _connection;
  StreamSubscription<CastPlayback>? _playbackSub;
  StreamSubscription<String>? _errorSub;
  Timer? _loadTimer;
  var _started = false;
  var _ending = false;
  var _startAt = Duration.zero;
  String? _audioLanguage;
  String? _subtitleLanguage;
  var _tracksApplied = false;
  var _subtitlesOff = false;

  /// Seconds since the receiver last reported a media position.
  var _sinceReport = 0;
  Object? _pendingSeek;
  Timer? _clock;
  String? _lastReported;
  var _disposed = false;

  List<CastTarget> get devices => _devices;
  bool get scanning => _scanning;
  CastState get state => _state;
  bool get isCasting => _state is CastConnecting || _state is CastActive;

  /// Scans the network once. Failures (no Wi-Fi, permission refused) leave
  /// the device list empty.
  Future<void> scan({Duration timeout = const Duration(seconds: 4)}) async {
    if (_scanning || _disposed) return;
    _scanning = true;
    _notify();
    try {
      final found = await _backend.discover(timeout: timeout);
      _devices = List.unmodifiable(found);
    } on Object catch (error) {
      debugPrint('[eyzflow-cast] discovery failed: $error');
    } finally {
      _scanning = false;
      _notify();
    }
  }

  /// Connects to [target]; when that fails for a network reason, scans again
  /// and retries once with the TV's current address. A TV that restarted
  /// listens on a new port, and the picker may still list the old one. A
  /// receiver the TV refused (`LAUNCH_ERROR`) is not retried.
  Future<CastConnection> _connect(CastTarget target, String appId) async {
    try {
      return await _backend.connect(target, appId: appId);
    } on Object catch (error) {
      if ('$error'.contains('LAUNCH_ERROR') || _disposed) rethrow;
      debugPrint('[eyzflow-cast] connect failed ($error); looking again');
      final found = await _backend.discover(
        timeout: const Duration(seconds: 4),
      );
      _devices = List.unmodifiable(found);
      _notify();
      final again = found.where((d) => d.id == target.id).firstOrNull;
      if (again == null || _disposed) rethrow;
      return _backend.connect(again, appId: appId);
    }
  }

  /// Hands playback to [target] with the receiver [appId].
  ///
  /// [audioLanguage] and [subtitleLanguage] are what the viewer chose on the
  /// phone; once the TV lists its tracks they are selected there by
  /// language. Null leaves the TV's default (a null subtitle language does
  /// not turn subtitles off). Set [subtitlesOff] to explicitly disable them.
  Future<void> cast(
    CastTarget target,
    CastMedia media, {
    required String appId,
    String? audioLanguage,
    String? subtitleLanguage,
    bool subtitlesOff = false,
  }) async {
    if (isCasting || _disposed) return;
    _audioLanguage = audioLanguage;
    _subtitleLanguage = subtitleLanguage;
    _tracksApplied = false;
    _subtitlesOff = subtitlesOff;
    _started = false;
    _pendingSeek = null;
    _ending = false;
    _lastReported = null;
    _startAt = media.startAt;
    _setState(CastConnecting(target));
    _sinceReport = 0;
    final CastConnection connection;
    try {
      connection = await _connect(target, appId);
    } on Object catch (error) {
      debugPrint('[eyzflow-cast] connect failed: $error');
      _setState(CastFailed(target, '$error'));
      onEnded?.call(CastEndReason.failed, media.startAt);
      return;
    }
    if (_disposed) {
      unawaited(connection.stop());
      return;
    }
    _connection = connection;
    var last = CastPlayback(position: media.startAt);
    _playbackSub = connection.playback.listen(
      (playback) {
        last = playback;
        _onPlayback(target, playback, media.startAt);
      },
      onDone: () => unawaited(
        _end(
          target,
          CastEndReason.disconnected,
          _positionOf(last, media.startAt),
        ),
      ),
    );
    _errorSub = connection.errors.listen((reason) {
      debugPrint('[eyzflow-cast] receiver refused: $reason');
      _fail(target, reason, _positionOf(last, media.startAt));
    });
    _loadTimer = Timer(loadTimeout, () {
      if (!_started) _fail(target, 'timeout', media.startAt);
    });
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    await connection.load(media);
  }

  /// A receiver only reports its position when its state changes; between
  /// reports the phone runs the clock itself while the TV plays, and asks
  /// for a fresh status every 15 s so the estimate cannot drift.
  void _tick() {
    final state = _state;
    if (_ending || state is! CastActive) return;
    final reported = state.playback;
    if (reported.state != CastPlayerState.playing && _pendingSeek == null) {
      return;
    }
    _sinceReport += 1;
    if (_sinceReport % 15 == 0) unawaited(_connection?.requestStatus());
    if (_pendingSeek != null) return;
    var position = reported.position + const Duration(seconds: 1);
    final duration = reported.duration;
    if (duration != null && position > duration) position = duration;
    final estimate = reported.atEstimatedPosition(position);
    _setState(CastActive(state.target, estimate));
    onPlayback?.call(estimate);
  }

  void _onPlayback(CastTarget target, CastPlayback playback, Duration startAt) {
    if (_ending) return;
    final reported = '${playback.state.name}/${playback.idleReason}';
    if (reported != _lastReported) {
      _lastReported = reported;
      debugPrint(
        '[eyzflow-cast] ${target.name}: ${playback.state.name}'
        '${playback.idleReason == null ? '' : ' (${playback.idleReason})'}'
        ' at ${playback.position}',
      );
    }
    if (playback.state == CastPlayerState.playing ||
        playback.state == CastPlayerState.paused) {
      _started = true;
      _loadTimer?.cancel();
    }
    if (playback.isFinished && _started) {
      unawaited(
        _end(
          target,
          CastEndReason.finished,
          playback.duration ?? playback.position,
        ),
      );
      return;
    }
    if (playback.isError) {
      _fail(target, 'ERROR', _positionOf(playback, startAt));
      return;
    }
    // Before the media started, the receiver reports idle with no reason.
    if (playback.state == CastPlayerState.idle && !_started) return;
    if (playback.hasFreshPosition) {
      _pendingSeek = null;
      _sinceReport = 0;
    } else {
      final current = _state;
      playback = playback.atEstimatedPosition(
        current is CastActive ? current.playback.position : startAt,
      );
    }
    if (!_tracksApplied && playback.tracks.isNotEmpty) {
      _tracksApplied = true;
      _applyPhoneTracks(playback);
    }
    _setState(CastActive(target, playback));
    onPlayback?.call(playback);
  }

  /// Selects the phone's languages on the TV, once its tracks are known.
  void _applyPhoneTracks(CastPlayback playback) {
    final int? audio = _byLanguage(
      playback.tracks,
      CastTrackKind.audio,
      _audioLanguage,
    );
    final int? subtitles = _byLanguage(
      playback.tracks,
      CastTrackKind.subtitles,
      _subtitleLanguage,
    );
    if (audio == null && subtitles == null && !_subtitlesOff) return;
    final List<int> withAudio = _withTrack(
      playback,
      CastTrackKind.audio,
      audio ?? _active(playback, CastTrackKind.audio),
    );
    final List<int> next = _withTrack(
      CastPlayback(tracks: playback.tracks, activeTrackIds: withAudio),
      CastTrackKind.subtitles,
      _subtitlesOff
          ? null
          : subtitles ?? _active(playback, CastTrackKind.subtitles),
    );
    if (playback.hasActiveTrackIds &&
        listEquals(next, playback.activeTrackIds)) {
      return;
    }
    unawaited(_setTracks(next));
  }

  /// Plays audio track [id] on the TV; the subtitles stay as they are.
  Future<void> selectAudio(int id) => _select(CastTrackKind.audio, id);

  /// Shows subtitle track [id] on the TV, or none for null; the audio stays.
  Future<void> selectSubtitles(int? id) => _select(CastTrackKind.subtitles, id);

  Future<void> _select(CastTrackKind kind, int? id) async {
    final state = _state;
    if (state is! CastActive) return;
    final List<int> next = _withTrack(state.playback, kind, id);
    if (state.playback.hasActiveTrackIds &&
        listEquals(next, state.playback.activeTrackIds)) {
      return;
    }
    await _setTracks(next);
  }

  Future<void> _setTracks(List<int> ids) async {
    try {
      await _connection?.setActiveTracks(ids);
    } on Object catch (error) {
      debugPrint('[eyzflow-cast] track switch failed: $error');
    }
  }

  /// The active ids with the [kind] track replaced by [id] (removed if null).
  static List<int> _withTrack(
    CastPlayback playback,
    CastTrackKind kind,
    int? id,
  ) {
    final Set<int> ofKind = {
      for (final t in playback.tracks)
        if (t.kind == kind) t.id,
    };
    return [
      for (final active in playback.activeTrackIds)
        if (!ofKind.contains(active)) active,
      ?id,
    ]..sort();
  }

  static int? _active(CastPlayback playback, CastTrackKind kind) => playback
      .tracks
      .where((t) => t.kind == kind && playback.activeTrackIds.contains(t.id))
      .map((t) => t.id)
      .firstOrNull;

  /// The first [kind] track in [language], compared by display name as the
  /// phone's panel does: EYZFlow tags one language differently across
  /// streams (`de`, `deu`, `de_DE`).
  static int? _byLanguage(
    List<CastTrack> tracks,
    CastTrackKind kind,
    String? language,
  ) {
    return tracks
        .where(
          (t) =>
              t.kind == kind &&
              EYZFlowLanguageNames.sameBaseLanguage(language, t.language),
        )
        .map((t) => t.id)
        .firstOrNull;
  }

  /// Before the receiver reported a position, the TV is where it started.
  static Duration _positionOf(CastPlayback playback, Duration startAt) =>
      playback.position > Duration.zero ? playback.position : startAt;

  Future<void> play() async => _connection?.play();
  Future<void> pause() async => _connection?.pause();
  Future<void> seek(Duration position) async {
    final connection = _connection;
    if (connection == null) return;
    final request = Object();
    _pendingSeek = request;
    try {
      await connection.seek(position);
    } catch (_) {
      if (identical(_pendingSeek, request)) _pendingSeek = null;
      rethrow;
    }
  }

  /// Stops casting. The player takes over at the TV's position.
  Future<void> stop() async {
    final state = _state;
    final target = switch (state) {
      CastConnecting(:final target) || CastActive(:final target) => target,
      _ => null,
    };
    if (target == null) return;
    final position = switch (state) {
      CastActive(:final playback) => _positionOf(playback, _startAt),
      _ => _startAt,
    };
    await _end(target, CastEndReason.stopped, position);
  }

  void _fail(CastTarget target, String reason, Duration position) {
    if (_ending) return;
    unawaited(_end(target, CastEndReason.failed, position, failure: reason));
  }

  /// Ends casting once, whichever way it ends.
  Future<void> _end(
    CastTarget target,
    CastEndReason reason,
    Duration position, {
    String? failure,
  }) async {
    if (_ending) return;
    _ending = true;
    _clock?.cancel();
    _clock = null;
    debugPrint(
      '[eyzflow-cast] ${target.name}: ended (${reason.name}'
      '${failure == null ? '' : ': $failure'}) at $position',
    );
    _loadTimer?.cancel();
    final connection = _connection;
    _connection = null;
    unawaited(_playbackSub?.cancel());
    unawaited(_errorSub?.cancel());
    _playbackSub = null;
    _errorSub = null;
    _setState(
      reason == CastEndReason.failed
          ? CastFailed(target, failure ?? 'failed')
          : const CastOff(),
    );
    onEnded?.call(reason, position);
    // A TV that closed the connection has nothing left to stop.
    if (connection != null && reason != CastEndReason.disconnected) {
      try {
        await connection.stop();
      } on Object catch (error) {
        debugPrint('[eyzflow-cast] stop failed: $error');
      }
    }
  }

  void _setState(CastState next) {
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadTimer?.cancel();
    _clock?.cancel();
    unawaited(_playbackSub?.cancel());
    unawaited(_errorSub?.cancel());
    final connection = _connection;
    _connection = null;
    if (connection != null) unawaited(connection.stop());
    super.dispose();
  }
}
