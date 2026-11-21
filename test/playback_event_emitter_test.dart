import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/playback_event_emitter.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const String _id = 'stream';
const Duration _length = Duration(minutes: 90);
const Duration _second = Duration(seconds: 1);

Duration _at(int seconds) => Duration(seconds: seconds);

VideoplaybackValue _playing(int seconds) => VideoplaybackValue(
  position: _at(seconds),
  duration: _length,
  isPlaying: true,
);

VideoplaybackValue _paused(int seconds) => VideoplaybackValue(
  position: _at(seconds),
  duration: _length,
  isPaused: true,
);

/// Runs [body] against an emitter whose clock is the fake one, so a test
/// decides how much wall-clock time passes between two ticks.
void _withEmitter(
  void Function(
    FakeAsync async,
    PlaybackEventEmitter emitter,
    List<PlaybackEvent> events,
  )
  body,
) {
  fakeAsync((FakeAsync async) {
    final List<PlaybackEvent> events = <PlaybackEvent>[];
    body(
      async,
      PlaybackEventEmitter(
        sourceId: _id,
        onEvent: events.add,
        clock: () => async.elapsed,
      ),
      events,
    );
  });
}

/// Brings playback to "started, one second in", and forgets the events that
/// took it there.
void _startPlaying(
  FakeAsync async,
  PlaybackEventEmitter emitter,
  List<PlaybackEvent> events,
) {
  emitter.ready();
  emitter.tick(_playing(0));
  async.elapse(_second);
  emitter.tick(_playing(1));
  events.clear();
}

void main() {
  test('Ready carries what the player knew when it initialized, once', () {
    _withEmitter((async, emitter, events) {
      emitter.ready(position: _at(1800), duration: _length);
      emitter.ready();

      expect(events, <PlaybackEvent>[
        PlaybackReady(sourceId: _id, position: _at(1800), duration: _length),
      ]);
    });
  });

  test('Started is reported once, on the first playing tick', () {
    _withEmitter((async, emitter, events) {
      emitter.ready();
      // Loaded and waiting for play: nothing to report yet.
      emitter.tick(
        const VideoplaybackValue(position: Duration.zero, duration: _length),
      );
      emitter.tick(_playing(0));
      async.elapse(_second);
      emitter.tick(_playing(1));

      expect(events, const <PlaybackEvent>[
        PlaybackReady(sourceId: _id, position: Duration.zero),
        PlaybackStarted(
          sourceId: _id,
          position: Duration.zero,
          duration: _length,
        ),
      ]);
    });
  });

  test('a player that never said it was ready is ready once it plays', () {
    _withEmitter((async, emitter, events) {
      emitter.tick(_playing(0));

      expect(events, const <PlaybackEvent>[
        PlaybackReady(
          sourceId: _id,
          position: Duration.zero,
          duration: _length,
        ),
        PlaybackStarted(
          sourceId: _id,
          position: Duration.zero,
          duration: _length,
        ),
      ]);
    });
  });

  test('a stalled start is neither a start nor a rebuffer', () {
    _withEmitter((async, emitter, events) {
      emitter.ready();
      // AVPlay: playing as soon as play is requested, first frame still to
      // come.
      emitter.tick(
        const VideoplaybackValue(
          position: Duration.zero,
          duration: _length,
          isPlaying: true,
          isBuffering: true,
        ),
      );
      // The Android plugin: buffering, then loaded, then playing.
      emitter.tick(
        const VideoplaybackValue(
          position: Duration.zero,
          duration: _length,
          isBuffering: true,
        ),
      );
      expect(events, hasLength(1));

      emitter.tick(_playing(0));
      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
      ]);
    });
  });

  test('Paused and Resumed follow the viewer, once each', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.tick(_paused(1));
      // The native controller repeats its state on every notification.
      emitter.tick(_paused(1));
      async.elapse(const Duration(minutes: 5));
      emitter.tick(_playing(1));
      emitter.tick(_playing(1));

      expect(events, <PlaybackEvent>[
        PlaybackPaused(sourceId: _id, position: _at(1), duration: _length),
        PlaybackResumed(sourceId: _id, position: _at(1), duration: _length),
      ]);
    });
  });

  test('a pause before Started is not reported', () {
    _withEmitter((async, emitter, events) {
      emitter.ready();
      events.clear();
      // What a freshly loaded player reports until play is requested.
      emitter.tick(_paused(0));

      expect(events, isEmpty);
    });
  });

  test('a stall is BufferingStarted and BufferingEnded, never a pause', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      // The Android plugin's spelling: buffering, then `loaded` — neither
      // playing nor paused — then playing again.
      emitter.tick(
        VideoplaybackValue(
          position: _at(1),
          duration: _length,
          isBuffering: true,
        ),
      );
      emitter.tick(VideoplaybackValue(position: _at(1), duration: _length));
      emitter.tick(_playing(1));
      // AVPlay's spelling: still "playing" throughout.
      emitter.tick(
        VideoplaybackValue(
          position: _at(1),
          duration: _length,
          isPlaying: true,
          isBuffering: true,
        ),
      );
      emitter.tick(_playing(1));

      final PlaybackEvent started = PlaybackBufferingStarted(
        sourceId: _id,
        position: _at(1),
        duration: _length,
      );
      final PlaybackEvent ended = PlaybackBufferingEnded(
        sourceId: _id,
        position: _at(1),
        duration: _length,
      );
      expect(events, <PlaybackEvent>[started, ended, started, ended]);
    });
  });

  test('each distinct error is reported once', () {
    _withEmitter((async, emitter, events) {
      // The native controller repeats the error on every tick, and the
      // session then hands the same message to the widget's failure path.
      emitter.tick(const VideoplaybackValue(errorMessage: 'boom'));
      emitter.tick(const VideoplaybackValue(errorMessage: 'boom'));
      emitter.error('boom');
      emitter.tick(const VideoplaybackValue(errorMessage: 'other'));

      expect(events, const <PlaybackEvent>[
        PlaybackError(sourceId: _id, message: 'boom', position: Duration.zero),
        PlaybackError(sourceId: _id, message: 'other', position: Duration.zero),
      ]);
    });
  });

  test('a startup failure that never reaches a tick is still an Error', () {
    _withEmitter((async, emitter, events) {
      emitter.error('Playback took too long to start.');

      expect(events, const <PlaybackEvent>[
        PlaybackError(
          sourceId: _id,
          message: 'Playback took too long to start.',
          position: Duration.zero,
        ),
      ]);
    });
  });

  test('Completed is reported once, and ticks after it report nothing', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);
      const VideoplaybackValue completed = VideoplaybackValue(
        position: _length,
        duration: _length,
        isCompleted: true,
      );

      emitter.tick(completed);
      emitter.tick(completed);
      // Both native players rewind and pause themselves once a film ends.
      emitter.tick(_paused(0));
      async.elapse(_second);
      emitter.tick(_playing(0));

      expect(events, const <PlaybackEvent>[
        PlaybackCompleted(sourceId: _id, position: _length, duration: _length),
      ]);
    });
  });

  test('the pause a player makes as it reaches the end is not a Paused', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);
      const Duration short = Duration(seconds: 3);

      // AVPlay pauses itself just before it reports completion.
      emitter.tick(
        const VideoplaybackValue(
          position: Duration(seconds: 2),
          duration: short,
          isPaused: true,
        ),
      );
      emitter.tick(
        const VideoplaybackValue(
          position: short,
          duration: short,
          isCompleted: true,
        ),
      );

      expect(events, const <PlaybackEvent>[
        PlaybackCompleted(sourceId: _id, position: short, duration: short),
      ]);
    });
  });

  test('a seek the overlay reports is Seeked with where it came from', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.seeked(_at(1), _at(61));

      expect(events, <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: _id,
          from: _at(1),
          position: _at(61),
          duration: _length,
        ),
      ]);
    });
  });

  test('the landing of a reported seek is not counted a second time', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.seeked(_at(1), _at(61));
      // A tick from before the native seek took hold, then the landing — a
      // segment boundary short of the target, as HLS seeks land.
      emitter.tick(_playing(1));
      async.elapse(const Duration(seconds: 2));
      emitter.tick(_playing(56));
      async.elapse(_second);
      emitter.tick(_playing(57));

      expect(events, hasLength(1));
      expect(events.single, isA<PlaybackSeeked>());
    });
  });

  test('a position jump is a seek made in the native controls', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      async.elapse(_second);
      emitter.tick(_playing(120));
      async.elapse(_second);
      emitter.tick(_playing(121));
      async.elapse(_second);
      emitter.tick(_playing(30));

      expect(events, <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: _id,
          from: _at(1),
          position: _at(120),
          duration: _length,
        ),
        PlaybackSeeked(
          sourceId: _id,
          from: _at(121),
          position: _at(30),
          duration: _length,
        ),
      ]);
    });
  });

  test('a seek made while paused is a seek, however long the pause', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);
      emitter.tick(_paused(1));
      events.clear();

      // Long enough that a playing film would have got there by itself.
      async.elapse(const Duration(minutes: 5));
      emitter.tick(_paused(31));

      expect(events, <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: _id,
          from: _at(1),
          position: _at(31),
          duration: _length,
        ),
      ]);
    });
  });

  test('a jump is its own seek once a reported seek has had time to land', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.seeked(_at(1), _at(61));
      emitter.tick(_playing(61));
      async.elapse(const Duration(seconds: 11));
      emitter.tick(_playing(72));
      async.elapse(_second);
      emitter.tick(_playing(300));

      expect(events, <PlaybackEvent>[
        PlaybackSeeked(
          sourceId: _id,
          from: _at(1),
          position: _at(61),
          duration: _length,
        ),
        PlaybackSeeked(
          sourceId: _id,
          from: _at(72),
          position: _at(300),
          duration: _length,
        ),
      ]);
    });
  });

  test('playing on is not a seek, however long the ticks stayed away', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      // Ordinary ticks.
      for (int second = 2; second <= 5; second++) {
        async.elapse(_second);
        emitter.tick(_playing(second));
      }
      // Picture-in-picture: the app is hidden, ticks stop, the film goes on.
      async.elapse(const Duration(minutes: 1));
      emitter.tick(_playing(65));
      // Double speed from the native controls.
      async.elapse(const Duration(seconds: 10));
      emitter.tick(_playing(85));
      // The small step back a player takes around a stall.
      async.elapse(_second);
      emitter.tick(_playing(84));

      expect(events, isEmpty);
    });
  });

  test('reaching the resume position is startup, not a seek', () {
    // Android: the resume seek runs on the paused player, before play.
    _withEmitter((async, emitter, events) {
      emitter.ready();
      emitter.tick(_paused(0));
      async.elapse(_second);
      emitter.tick(_paused(1800));
      emitter.tick(_playing(1800));
      async.elapse(_second);
      emitter.tick(_playing(1801));

      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
      ]);
      expect(events.last.position, _at(1800));
    });

    // Tizen: AVPlay opens at the resume position, but says "playing" before
    // it has polled a position, so the first one it reports is zero.
    _withEmitter((async, emitter, events) {
      emitter.ready();
      emitter.tick(_playing(0));
      emitter.tick(_playing(0));
      async.elapse(const Duration(milliseconds: 500));
      emitter.tick(_playing(1800));
      async.elapse(_second);
      emitter.tick(_playing(1801));

      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackReady,
        PlaybackStarted,
      ]);
    });
  });

  test('an audio switch is AudioTrackChanged with its language', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.audioTrackChanged('en');

      expect(events, <PlaybackEvent>[
        PlaybackAudioTrackChanged(
          sourceId: _id,
          position: _at(1),
          duration: _length,
          language: 'en',
        ),
      ]);
    });
  });

  test('a subtitle switch is SubtitleTrackChanged, null for off', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.subtitleTrackChanged('de');
      emitter.subtitleTrackChanged(null);

      expect(events, <PlaybackEvent>[
        PlaybackSubtitleTrackChanged(
          sourceId: _id,
          position: _at(1),
          duration: _length,
          language: 'de',
        ),
        PlaybackSubtitleTrackChanged(
          sourceId: _id,
          position: _at(1),
          duration: _length,
        ),
      ]);
    });
  });

  test('Closed is reported once, and nothing follows it', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);

      emitter.close();
      emitter.close();
      // A retired session can still tick while it is being disposed.
      emitter.tick(_paused(1));
      emitter.tick(const VideoplaybackValue(errorMessage: 'late'));
      emitter.ready();
      emitter.seeked(_at(1), _at(61));
      emitter.audioTrackChanged('en');
      emitter.subtitleTrackChanged(null);
      emitter.error('late');

      expect(events, <PlaybackEvent>[
        PlaybackClosed(sourceId: _id, position: _at(1), duration: _length),
      ]);
    });
  });

  test('a player that fails before it starts reports Error, then Closed', () {
    _withEmitter((async, emitter, events) {
      emitter.error('Unable to load the video source: boom');
      emitter.close();

      expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
        PlaybackError,
        PlaybackClosed,
      ]);
    });
  });

  test('without a callback the emitter does nothing at all', () {
    int clockReads = 0;
    final PlaybackEventEmitter emitter = PlaybackEventEmitter(
      sourceId: _id,
      onEvent: null,
      clock: () {
        clockReads++;
        return Duration.zero;
      },
    );

    emitter.ready();
    emitter.tick(_playing(0));
    emitter.tick(_paused(0));
    emitter.seeked(Duration.zero, _at(60));
    emitter.tick(const VideoplaybackValue(errorMessage: 'boom'));

    // Not even bookkeeping: a callback arriving later starts from scratch.
    expect(clockReads, 0);
    final List<PlaybackEvent> events = <PlaybackEvent>[];
    emitter.onEvent = events.add;
    emitter.tick(_playing(5));
    expect(events.map((PlaybackEvent e) => e.runtimeType), <Type>[
      PlaybackReady,
      PlaybackStarted,
    ]);

    // And closing without one is silent.
    PlaybackEventEmitter(sourceId: _id, onEvent: null).close();
  });

  test('a replaced callback carries the same sequence on', () {
    _withEmitter((async, emitter, events) {
      _startPlaying(async, emitter, events);
      final List<PlaybackEvent> rebuilt = <PlaybackEvent>[];

      // A host rebuilding its view passes a new closure.
      emitter.onEvent = rebuilt.add;
      emitter.tick(_paused(1));

      expect(events, isEmpty);
      expect(rebuilt.single, isA<PlaybackPaused>());
    });
  });

  test('a callback that throws does not reach the player', () {
    final PlaybackEventEmitter emitter = PlaybackEventEmitter(
      sourceId: _id,
      onEvent: (PlaybackEvent event) => throw StateError('host bug'),
    );

    // The player's own listener is on this call stack.
    emitter.tick(_playing(0));
    emitter.close();
  });
}
