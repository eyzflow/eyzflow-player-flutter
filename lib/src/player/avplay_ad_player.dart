import 'package:flutter/widgets.dart';
import 'package:video_player_avplay/video_player.dart';
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as avplay;

import '../ads/vast.dart';
import '../ads/vast_ad_driver.dart';

/// One ad's media file in its own AVPlay player (Tizen).
///
/// A second native player next to the film's: the film's is paused and
/// deactivated first, so this one gets the TV's video decoder.
final class AvplayAdMediaPlayer implements AdMediaPlayer {
  AvplayAdMediaPlayer(VastMediaFile media)
    : _controller = VideoPlayerController.network(
        media.url.toString(),
        formatHint: media.isHls ? avplay.VideoFormat.hls : null,
      );

  final VideoPlayerController _controller;
  final Map<VoidCallback, VoidCallback> _listeners =
      <VoidCallback, VoidCallback>{};

  @override
  AdMediaValue get value {
    final VideoPlayerValue v = _controller.value;
    return AdMediaValue(
      isInitialized: v.isInitialized,
      isPlaying: v.isPlaying,
      isCompleted: v.isCompleted,
      position: v.position,
      duration: v.isInitialized && v.duration.end > Duration.zero
          ? v.duration.end
          : null,
      errorMessage: v.hasError ? v.errorDescription : null,
    );
  }

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  void addListener(VoidCallback listener) {
    void relay() => listener();
    _listeners[listener] = relay;
    _controller.addListener(relay);
  }

  @override
  void removeListener(VoidCallback listener) {
    final VoidCallback? relay = _listeners.remove(listener);
    if (relay != null) _controller.removeListener(relay);
  }

  @override
  Widget buildView() => Center(
    child: AspectRatio(
      aspectRatio: _controller.value.isInitialized
          ? _controller.value.aspectRatio
          : 16 / 9,
      child: VideoPlayer(_controller),
    ),
  );
}
