import '../player/playback_event.dart';

import '../core/analytics/collector.dart';

/// Feeds the player's [PlaybackEvent]s into a [BeatCollector].
///
/// The players report state changes only, with the position at each; the
/// collector estimates the position in between.
final class PlaybackEventAdapter {
  PlaybackEventAdapter(this.collector);

  final BeatCollector collector;
  var _playing = false;

  void add(PlaybackEvent event) {
    final position = event.position;
    final duration = event.duration;
    switch (event) {
      case PlaybackReady():
        collector.ready(position: position, duration: duration);
      case PlaybackStarted() || PlaybackResumed():
        _playing = true;
        collector.playing(position: position, duration: duration);
      case PlaybackPaused():
        _playing = false;
        collector.paused(position: position, duration: duration);
      case PlaybackBufferingStarted():
        collector.bufferingStarted(position: position, duration: duration);
      case PlaybackBufferingEnded():
        collector.bufferingEnded(
          position: position,
          duration: duration,
          isPlaying: _playing,
        );
      case PlaybackSeeked():
        collector.seeked(to: position, duration: duration);
      case PlaybackError(:final message):
        collector.error(
          code: 'PLAYBACK_FAILED',
          message: message,
          position: position,
        );
      case PlaybackCompleted():
        _playing = false;
        collector.completed(position: position, duration: duration);
      case PlaybackClosed():
        collector.position(position, duration: duration);
      case PlaybackAudioTrackChanged() || PlaybackSubtitleTrackChanged():
        collector.position(position, duration: duration);
      case PlaybackAdBreakStarted():
        collector.beginAd();
      case PlaybackAdBreakEnded():
        collector.endAd();
    }
  }
}
