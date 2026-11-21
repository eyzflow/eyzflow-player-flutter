part of 'native_video_player_controller.dart';

/// A native interruption or terminal close, scoped to this controller.
class AndroidPlaybackEvent {
  const AndroidPlaybackEvent({
    required this.reason,
    required this.position,
    required this.closed,
  });
  final String reason;
  final Duration position;
  final bool closed;
}

extension AndroidPlaybackController on NativeVideoPlayerController {
  bool get _isAndroidPlayback =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Stream<AndroidPlaybackEvent> get androidPlaybackEvents =>
      _androidPlaybackEvents.stream;

  /// Taps on the fullscreen route's Cast button, with the playback position
  /// at the tap (EYZFlow patch). Playback goes on; the app decides.
  Stream<Duration> get androidCastRequests => _androidCastRequests.stream;

  /// Shows or hides the fullscreen route's Cast button (EYZFlow patch). The
  /// app shows it once it found a Cast device.
  Future<void> setAndroidCastButtonVisible(bool visible) async {
    await _androidInvoke<void>('setCastButtonVisible', {'visible': visible});
  }

  Future<T?> _androidInvoke<T>(
    String method, [
    Map<String, Object> arguments = const {},
  ]) async {
    if (!_isAndroidPlayback || _isDisposed) return null;
    return NativeVideoPlayerController._pluginMethodChannel.invokeMethod<T>(
      method,
      {'controllerId': id, ...arguments},
    );
  }

  Future<void> setAndroidPlayerRouteActive(bool active) async {
    await _androidInvoke<void>('setPlayerRouteActive', {'active': active});
  }

  Future<int> getAndroidPlaybackIntentRevision() async =>
      await _androidInvoke<int>('getPlaybackIntentRevision') ?? -1;

  Future<void> playIfAndroidIntentUnchanged(int revision) async {
    await _androidInvoke<void>('playIfIntentUnchanged', {'revision': revision});
  }

  Future<void> _setAndroidPipPolicy(bool automatic) async {
    await _androidInvoke<void>('setPictureInPicturePolicy', {
      'allowed': allowsPictureInPicture,
      'automatic': automatic,
    });
  }

  bool _handleAndroidPlaybackEvent(Map<dynamic, dynamic> map) {
    if (!_isAndroidPlayback || _isDisposed) return false;
    final name = map['event'];
    if (name == 'castRequested') {
      if (!_androidCastRequests.isClosed) {
        _androidCastRequests.add(
          Duration(milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0),
        );
      }
      return true;
    }
    if (name != 'playbackPaused' && name != 'playbackClosed') return false;
    final reason = map['reason'];
    const reasons = {
      'hidden',
      'screenOff',
      'audioFocus',
      'noisy',
      'user',
      'pipDismissed',
      'closeButton',
    };
    if (reason is! String || !reasons.contains(reason)) return true;
    final position = Duration(
      milliseconds: (map['positionMs'] as num?)?.toInt() ?? 0,
    );
    _updateState(
      _state.copyWith(
        activityState: PlayerActivityState.paused,
        currentPosition: position,
      ),
    );
    _androidPlaybackEvents.add(
      AndroidPlaybackEvent(
        reason: reason,
        position: position,
        closed: name == 'playbackClosed',
      ),
    );
    return true;
  }
}
