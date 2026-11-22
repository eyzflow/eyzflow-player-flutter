import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter_test/flutter_test.dart';

const Duration _position = Duration(minutes: 1);
const Duration _length = Duration(minutes: 90);

void main() {
  test('events are values: same kind and fields are equal', () {
    expect(
      const PlaybackPaused(
        sourceId: 'stream',
        position: _position,
        duration: _length,
      ),
      const PlaybackPaused(
        sourceId: 'stream',
        position: _position,
        duration: _length,
      ),
    );
    // Same fields, different kind.
    expect(
      const PlaybackPaused(sourceId: 'stream', position: _position),
      isNot(const PlaybackResumed(sourceId: 'stream', position: _position)),
    );
    // The fields a kind adds count too.
    expect(
      const PlaybackSeeked(
        sourceId: 'stream',
        from: Duration.zero,
        position: _position,
      ),
      isNot(
        const PlaybackSeeked(
          sourceId: 'stream',
          from: Duration(seconds: 15),
          position: _position,
        ),
      ),
    );
    expect(
      const PlaybackError(
        sourceId: 'stream',
        message: 'boom',
        position: _position,
      ),
      isNot(
        const PlaybackError(
          sourceId: 'stream',
          message: 'other',
          position: _position,
        ),
      ),
    );
    expect(
      const PlaybackSubtitleTrackChanged(
        sourceId: 'stream',
        position: _position,
        language: 'de',
      ),
      isNot(
        const PlaybackSubtitleTrackChanged(
          sourceId: 'stream',
          position: _position,
        ),
      ),
    );
    expect(
      const PlaybackAudioTrackChanged(
        sourceId: 'stream',
        position: _position,
        language: 'de',
      ),
      isNot(
        const PlaybackAudioTrackChanged(
          sourceId: 'stream',
          position: _position,
          language: 'en',
        ),
      ),
    );
  });

  test('toString names the event and everything it carries', () {
    expect(
      const PlaybackStarted(
        sourceId: 'stream',
        position: Duration.zero,
      ).toString(),
      'PlaybackStarted(sourceId: stream, position: 0:00:00)',
    );
    expect(
      const PlaybackSeeked(
        sourceId: 'stream',
        from: Duration(seconds: 15),
        position: _position,
        duration: _length,
      ).toString(),
      'PlaybackSeeked(sourceId: stream, position: 0:01:00, '
      'duration: 1:30:00, from: 0:00:15)',
    );
    expect(
      const PlaybackError(
        sourceId: 'stream',
        message: 'boom',
        position: _position,
      ).toString(),
      'PlaybackError(sourceId: stream, position: 0:01:00, message: boom)',
    );
    expect(
      const PlaybackSubtitleTrackChanged(
        sourceId: 'stream',
        position: _position,
      ).toString(),
      'PlaybackSubtitleTrackChanged(sourceId: stream, position: 0:01:00, '
      'language: null)',
    );
  });

  test('a host can switch over every kind of event', () {
    // Compiles only while this switch is exhaustive, which is what lets a
    // host find out at build time that an event was added.
    String label(PlaybackEvent event) => switch (event) {
      PlaybackReady() => 'ready',
      PlaybackStarted() => 'started',
      PlaybackPaused() => 'paused',
      PlaybackResumed() => 'resumed',
      PlaybackSeeked(:final from) => 'seeked from $from',
      PlaybackBufferingStarted() => 'buffering started',
      PlaybackBufferingEnded() => 'buffering ended',
      PlaybackError(:final message) => 'error $message',
      PlaybackAudioTrackChanged(:final language) => 'audio $language',
      PlaybackSubtitleTrackChanged(:final language) => 'subtitles $language',
      PlaybackAdBreakStarted() => 'ad break started',
      PlaybackAdBreakEnded() => 'ad break ended',
      PlaybackCompleted() => 'completed',
      PlaybackClosed() => 'closed',
    };

    expect(
      label(const PlaybackClosed(sourceId: 'stream', position: _position)),
      'closed',
    );
  });
}
