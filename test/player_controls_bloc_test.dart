import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/player_controls_bloc.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _fast = Duration(milliseconds: 100);

PlayerControlsBloc _bloc({
  _FakePlayback? playback,
  SubtitlePreferenceStore? store,
  void Function(Duration from, Duration to)? onSeeked,
  void Function(String? language)? onAudioTrackChanged,
  void Function(String? language)? onSubtitleTrackChanged,
  // Most tests here are about what a seek does, so a skip seeks at once;
  // the burst tests below pass the production delay.
  Duration skipCommitDelay = Duration.zero,
}) {
  final p = playback ?? _FakePlayback();
  return PlayerControlsBloc(
    controller: p,
    tracks: p,
    subtitlePreferenceStore: store,
    autoHide: _fast,
    skipCommitDelay: skipCommitDelay,
    onSeeked: onSeeked,
    onAudioTrackChanged: onAudioTrackChanged,
    onSubtitleTrackChanged: onSubtitleTrackChanged,
  );
}

/// Shows the player in German, so the remembered-language match runs against
/// German names the way it does in the app.
Future<void> _loadGermanNames() async => setEYZFlowPlayerLanguage('de');

void main() {
  setUp(() => setEYZFlowPlayerLanguage('en'));
  tearDown(() => setEYZFlowPlayerLanguage(null));

  test(
    'a burst of skips never overlaps native seeks and lands on the last',
    () {
      fakeAsync((async) {
        final playback = _FakePlayback()..seekLatency = _fast;
        final bloc = _bloc(playback: playback);
        bloc.add(
          const PlayerControlsValueTicked(
            position: Duration.zero,
            duration: Duration(minutes: 90),
            isPlaying: true,
          ),
        );
        async.flushMicrotasks();
        for (var i = 0; i < 4; i++) {
          bloc.add(const PlayerControlsSkipBy(1));
        }
        async.elapse(_fast * 10);

        expect(playback.seekOverlapped, isFalse);
        expect(playback.lastSeek, const Duration(seconds: 60));
        expect(playback.seeks.length, lessThan(4));
        bloc.close();
      });
    },
  );

  group('a skip burst', () {
    const delay = Duration(milliseconds: 600);

    PlayerControlsBloc burstBloc(_FakePlayback playback, {Duration? at}) {
      final bloc = _bloc(playback: playback, skipCommitDelay: delay);
      bloc.add(
        PlayerControlsValueTicked(
          position: at ?? const Duration(minutes: 10),
          duration: const Duration(minutes: 90),
          isPlaying: true,
        ),
      );
      return bloc;
    }

    test('moves the shown position at once and seeks once after it', () {
      fakeAsync((async) {
        final playback = _FakePlayback();
        final seeks = <(Duration, Duration)>[];
        final bloc =
            _bloc(
              playback: playback,
              skipCommitDelay: delay,
              onSeeked: (from, to) => seeks.add((from, to)),
            )..add(
              const PlayerControlsValueTicked(
                position: Duration(minutes: 10),
                duration: Duration(minutes: 90),
                isPlaying: true,
              ),
            );
        async.flushMicrotasks();

        for (var i = 0; i < 4; i++) {
          bloc.add(const PlayerControlsSkipBy(1));
          async.elapse(const Duration(milliseconds: 200));
        }
        expect(bloc.state.position, const Duration(minutes: 11));
        expect(playback.seeks, isEmpty);

        async.elapse(delay);
        expect(playback.seeks, [const Duration(minutes: 11)]);
        expect(seeks, [
          (const Duration(minutes: 10), const Duration(minutes: 11)),
        ]);
        bloc.close();
      });
    });

    test('ticks do not pull the preview back while the burst is open', () {
      fakeAsync((async) {
        final bloc = burstBloc(_FakePlayback());
        async.flushMicrotasks();
        bloc
          ..add(const PlayerControlsSkipBy(-1))
          ..add(
            const PlayerControlsValueTicked(
              position: Duration(minutes: 10, seconds: 1),
              duration: Duration(minutes: 90),
              isPlaying: true,
            ),
          );
        async.flushMicrotasks();
        expect(bloc.state.position, const Duration(minutes: 9, seconds: 45));
        bloc.close();
      });
    });

    test('holding speeds up from 15 s to 30 s to 60 s steps', () {
      fakeAsync((async) {
        final playback = _FakePlayback();
        final bloc = burstBloc(playback, at: Duration.zero);
        async.flushMicrotasks();
        // A held key repeats faster than the commit delay.
        for (var i = 0; i < 12; i++) {
          bloc.add(const PlayerControlsSkipBy(1));
          async.elapse(const Duration(milliseconds: 50));
        }
        // 4 × 15 s + 6 × 30 s + 2 × 60 s
        expect(bloc.state.position, const Duration(seconds: 60 + 180 + 120));
        async.elapse(delay);
        expect(playback.seeks, [const Duration(seconds: 360)]);

        // The next burst starts slow again.
        bloc.add(const PlayerControlsSkipBy(1));
        async.elapse(delay);
        expect(playback.lastSeek, const Duration(seconds: 375));
        bloc.close();
      });
    });

    test('an explicit seek takes over from an open burst', () {
      fakeAsync((async) {
        final playback = _FakePlayback();
        final bloc = burstBloc(playback);
        async.flushMicrotasks();
        bloc
          ..add(const PlayerControlsSkipBy(1))
          ..add(const PlayerControlsSeekRequested(Duration(minutes: 30)));
        async.elapse(delay * 2);
        expect(playback.seeks, [const Duration(minutes: 30)]);
        bloc.close();
      });
    });

    test('the overlay stays up until the burst has seeked', () {
      fakeAsync((async) {
        final bloc = burstBloc(_FakePlayback());
        async.flushMicrotasks();
        bloc.add(const PlayerControlsSkipBy(1));
        // Longer than the test auto-hide, shorter than the commit delay.
        async.elapse(_fast * 3);
        expect(bloc.state.visible, isTrue);
        async.elapse(delay + _fast * 2);
        expect(bloc.state.visible, isFalse);
        bloc.close();
      });
    });
  });

  test('activity shows the overlay; the timer hides it', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(const PlayerControlsActivity());
      async.flushMicrotasks();
      expect(bloc.state.visible, isTrue);
      async.elapse(_fast + const Duration(milliseconds: 10));
      expect(bloc.state.visible, isFalse);
      bloc.close();
    });
  });

  test('an idle timeout takes an open panel down with the overlay', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
      async.flushMicrotasks();
      expect(bloc.state.activePanel, PlayerPanel.audio);

      // Opening the panel restarts the countdown; it does not suspend it.
      async.elapse(_fast + const Duration(milliseconds: 10));
      expect(bloc.state.visible, isFalse);
      expect(bloc.state.activePanel, PlayerPanel.none);
      bloc.close();
    });
  });

  test('input while a panel is open restarts the countdown', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
      async.flushMicrotasks();

      // Three-quarters of the way through, the viewer moves in the list.
      async.elapse(_fast * 0.75);
      bloc.add(const PlayerControlsActivity());
      async.flushMicrotasks();
      async.elapse(_fast * 0.75);

      // Past the original deadline, short of the restarted one.
      expect(bloc.state.visible, isTrue);
      expect(bloc.state.activePanel, PlayerPanel.audio);
      bloc.close();
    });
  });

  test('skip forward and backward clamp to [0, duration]', () async {
    final p = _FakePlayback();
    final bloc = _bloc(playback: p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 5),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;

    bloc.add(const PlayerControlsSkipBy(-1)); // 5 - 15 -> 0
    await bloc.stream.firstWhere((s) => s.position == Duration.zero);
    expect(p.lastSeek, Duration.zero);

    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 18),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsSkipBy(1)); // 18 + 15 -> 20 (clamped)
    await bloc.stream.firstWhere(
      (s) => s.position == const Duration(seconds: 20),
    );
    expect(p.lastSeek, const Duration(seconds: 20));
    await bloc.close();
  });

  test('play/pause toggles the controller based on state', () async {
    final p = _FakePlayback();
    final bloc = _bloc(playback: p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration.zero,
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsPlayPauseToggled());
    await bloc.stream.first;
    expect(p.pauseCount, 1);
    expect(p.playCount, 0);
    await bloc.close();
  });

  test('scrub pauses then resumes only when it had been playing', () async {
    final p = _FakePlayback();
    final bloc = _bloc(playback: p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 2),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsScrubStarted());
    await bloc.stream.firstWhere((s) => s.isScrubbing);
    expect(p.pauseCount, 1);
    bloc.add(const PlayerControlsScrubEnded(Duration(seconds: 9)));
    await bloc.stream.firstWhere((s) => !s.isScrubbing);
    expect(p.lastSeek, const Duration(seconds: 9));
    expect(p.playCount, 1);
    await bloc.close();
  });

  test('ticks do not move position while scrubbing', () async {
    final p = _FakePlayback();
    final bloc = _bloc(playback: p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 2),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsScrubStarted());
    await bloc.stream.firstWhere((s) => s.isScrubbing);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 3),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    expect(bloc.state.position, const Duration(seconds: 2));
    await bloc.close();
  });

  test('TracksLoaded restores a matching remembered language', () async {
    final store = SubtitlePreferenceStore()..remember('en');
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, store: store);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
          PlayerTextTrack(trackId: 2, language: 'en'),
        ],
      ),
    );
    await bloc.stream.first;
    expect(bloc.state.selectedTextTrackId, 2);
    expect(p.lastTextSelection, 2);
    await bloc.close();
  });

  test(
    'TracksLoaded selects nothing when the language is unavailable',
    () async {
      final store = SubtitlePreferenceStore()..remember('fr');
      final p = _FakePlayback();
      final bloc = _bloc(playback: p, store: store);
      bloc.add(
        const PlayerControlsTracksLoaded(
          audioTracks: <PlayerAudioTrack>[],
          textTracks: <PlayerTextTrack>[
            PlayerTextTrack(trackId: 1, language: 'de'),
          ],
        ),
      );
      await bloc.stream.first;
      expect(bloc.state.selectedTextTrackId, isNull);
      expect(p.textSelectionCleared, isTrue);
      await bloc.close();
    },
  );

  test(
    'TracksLoaded matches a remembered language across code forms',
    () async {
      // The same language, tagged differently by two streams. A raw-code
      // comparison lost the preference on the next film.
      await _loadGermanNames();
      final store = SubtitlePreferenceStore()..remember('deu');
      final p = _FakePlayback();
      final bloc = _bloc(playback: p, store: store);
      bloc.add(
        const PlayerControlsTracksLoaded(
          audioTracks: <PlayerAudioTrack>[],
          textTracks: <PlayerTextTrack>[
            PlayerTextTrack(trackId: 1, language: 'en'),
            PlayerTextTrack(trackId: 2, language: 'de_DE'),
          ],
        ),
      );
      await bloc.stream.first;
      expect(bloc.state.selectedTextTrackId, 2);
      expect(p.lastTextSelection, 2);
      await bloc.close();
    },
  );

  test('TracksLoaded never matches an undetermined track', () async {
    await _loadGermanNames();
    final store = SubtitlePreferenceStore()..remember('zxx');
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, store: store);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'und'),
        ],
      ),
    );
    await bloc.stream.first;
    expect(bloc.state.selectedTextTrackId, isNull);
    expect(p.textSelectionCleared, isTrue);
    await bloc.close();
  });

  test('TracksLoaded clears subtitles on a remembered off', () async {
    final store = SubtitlePreferenceStore()..rememberOff();
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, store: store);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await bloc.stream.first;
    expect(bloc.state.selectedTextTrackId, isNull);
    expect(p.textSelectionCleared, isTrue);
    await bloc.close();
  });

  test(
    'selecting a subtitle records its language and closes the panel',
    () async {
      final store = SubtitlePreferenceStore();
      final p = _FakePlayback();
      final bloc = _bloc(playback: p, store: store);
      bloc.add(
        const PlayerControlsTracksLoaded(
          audioTracks: <PlayerAudioTrack>[],
          textTracks: <PlayerTextTrack>[
            PlayerTextTrack(trackId: 1, language: 'de'),
          ],
        ),
      );
      await bloc.stream.first;
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.subtitles));
      await bloc.stream.first;
      bloc.add(const PlayerControlsTextSelected(1));
      await bloc.stream.firstWhere((s) => s.activePanel == PlayerPanel.none);
      expect(bloc.state.selectedTextTrackId, 1);
      expect(store.languageCode, 'de');
      await bloc.close();
    },
  );

  test('selecting subtitles off records off', () async {
    final store = SubtitlePreferenceStore();
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, store: store);
    bloc.add(const PlayerControlsTextSelected(null));
    await bloc.stream.first;
    expect(store.hasPreference, isTrue);
    expect(store.languageCode, isNull);
    await bloc.close();
  });

  test('a refused selection still closes the panel', () async {
    // Leaving the sidebar open on a native refusal handed the viewer a panel
    // that answered nothing. The unmoved checkmark is what says the switch
    // did not take.
    final p = _FakePlayback()..selectionSucceeds = false;
    final bloc = _bloc(playback: p);
    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
    await bloc.stream.first;
    bloc.add(const PlayerControlsAudioSelected(4));
    await bloc.stream.firstWhere((s) => s.activePanel == PlayerPanel.none);
    expect(bloc.state.selectedAudioTrackId, isNull);
    await bloc.close();
  });

  test('picking the row already checked closes the panel without a native '
      'call', () async {
    // What the native player reports as playing.
    final p = _FakePlayback()..selectedTextTrackId = 1;
    final bloc = _bloc(playback: p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsTextSelected(1));
    await bloc.stream.first;
    expect(bloc.state.selectedTextTrackId, 1);
    // Selection was never re-sent: on a TV that is a real operation.
    expect(p.lastTextSelection, isNull);
    await bloc.close();
  });

  test('an active scrub suspends auto-hide', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(
        const PlayerControlsValueTicked(
          position: Duration(seconds: 10),
          duration: Duration(seconds: 600),
          isPlaying: true,
        ),
      );
      bloc.add(const PlayerControlsScrubStarted());
      async.flushMicrotasks();
      expect(bloc.state.isScrubbing, isTrue);

      // Any remote key during the drag wakes the overlay, which re-arms the
      // auto-hide timer. On a TV that is every arrow press used to scrub.
      bloc.add(const PlayerControlsActivity());
      async.flushMicrotasks();

      async.elapse(_fast + const Duration(milliseconds: 10));
      expect(bloc.state.visible, isTrue);
      bloc.close();
    });
  });

  test('a stale idle timeout is dropped', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(const PlayerControlsActivity());
      async.flushMicrotasks();
      // A panel opens, restarting the countdown — but the previous timer had
      // already queued its timeout behind that event.
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
      async.flushMicrotasks();
      bloc.add(const PlayerControlsHideRequested(idleGeneration: 1));
      async.flushMicrotasks();

      // The menu must not flash open and vanish.
      expect(bloc.state.activePanel, PlayerPanel.audio);
      expect(bloc.state.visible, isTrue);
      bloc.close();
    });
  });

  test('a skip and a seek request report where from and where to', () async {
    final seeks = <(Duration, Duration)>[];
    final bloc = _bloc(onSeeked: (from, to) => seeks.add((from, to)));
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 5),
        duration: Duration(minutes: 90),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;

    bloc.add(const PlayerControlsSkipBy(1));
    await bloc.stream.firstWhere(
      (s) => s.position == const Duration(seconds: 20),
    );
    bloc.add(const PlayerControlsSeekRequested(Duration(minutes: 10)));
    await bloc.stream.firstWhere(
      (s) => s.position == const Duration(minutes: 10),
    );

    expect(seeks, const <(Duration, Duration)>[
      (Duration(seconds: 5), Duration(seconds: 20)),
      (Duration(seconds: 20), Duration(minutes: 10)),
    ]);
    await bloc.close();
  });

  test('a burst reports the seeks that were issued, not the presses', () {
    fakeAsync((async) {
      final playback = _FakePlayback()..seekLatency = _fast;
      final seeks = <(Duration, Duration)>[];
      final bloc = _bloc(
        playback: playback,
        onSeeked: (from, to) => seeks.add((from, to)),
      );
      bloc.add(
        const PlayerControlsValueTicked(
          position: Duration.zero,
          duration: Duration(minutes: 90),
          isPlaying: true,
        ),
      );
      async.flushMicrotasks();
      for (var i = 0; i < 4; i++) {
        bloc.add(const PlayerControlsSkipBy(1));
      }
      async.flushMicrotasks();
      // Reported as the first is handed over, not once it lands: the position
      // moves while the native seek is still in flight.
      expect(seeks, const <(Duration, Duration)>[
        (Duration.zero, Duration(seconds: 15)),
      ]);

      async.elapse(_fast * 10);
      // The three presses that queued behind it collapsed into one seek,
      // which starts where the first one left playback.
      expect(seeks, const <(Duration, Duration)>[
        (Duration.zero, Duration(seconds: 15)),
        (Duration(seconds: 15), Duration(seconds: 60)),
      ]);
      expect(playback.seeks, <Duration>[for (final seek in seeks) seek.$2]);
      bloc.close();
    });
  });

  test('a skip clamped to where playback already is reports no seek', () async {
    final seeks = <(Duration, Duration)>[];
    final p = _FakePlayback();
    final bloc = _bloc(
      playback: p,
      onSeeked: (from, to) => seeks.add((from, to)),
    );
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration.zero,
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;

    bloc.add(const PlayerControlsSkipBy(-1));
    await bloc.stream.first;
    await Future<void>.delayed(Duration.zero);

    expect(p.lastSeek, Duration.zero);
    expect(seeks, isEmpty);
    await bloc.close();
  });

  test('a scrub reports one seek, from where the drag began', () async {
    final seeks = <(Duration, Duration)>[];
    final bloc = _bloc(onSeeked: (from, to) => seeks.add((from, to)));
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 2),
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await bloc.stream.first;
    bloc.add(const PlayerControlsScrubStarted());
    await bloc.stream.firstWhere((s) => s.isScrubbing);
    bloc.add(const PlayerControlsScrubEnded(Duration(seconds: 9)));
    await bloc.stream.firstWhere((s) => !s.isScrubbing);

    expect(seeks, const <(Duration, Duration)>[
      (Duration(seconds: 2), Duration(seconds: 9)),
    ]);
    await bloc.close();
  });

  test('an audio switch reports the new language, once it took', () async {
    final languages = <String?>[];
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, onAudioTrackChanged: languages.add);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'de'),
          PlayerAudioTrack(trackId: 2, language: 'en'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await bloc.stream.first;

    // Each pick is made from the open panel, and closes it.
    Future<void> pick(int trackId) async {
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
      await bloc.stream.firstWhere((s) => s.activePanel == PlayerPanel.audio);
      bloc.add(PlayerControlsAudioSelected(trackId));
      await bloc.stream.firstWhere((s) => s.activePanel == PlayerPanel.none);
    }

    await pick(2);
    // OK on the row already playing is a dismissal, not a switch.
    await pick(2);
    // A firmware that refuses the switch has not changed the track.
    p.selectionSucceeds = false;
    await pick(1);

    expect(bloc.state.selectedAudioTrackId, 2);
    expect(languages, <String?>['en']);
    await bloc.close();
  });

  test('a subtitle switch reports the language, and off as null', () async {
    final languages = <String?>[];
    final p = _FakePlayback();
    final bloc = _bloc(playback: p, onSubtitleTrackChanged: languages.add);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await bloc.stream.first;

    // Each pick is made from the open panel, and closes it.
    Future<void> pick(int? trackId) async {
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.subtitles));
      await bloc.stream.firstWhere(
        (s) => s.activePanel == PlayerPanel.subtitles,
      );
      bloc.add(PlayerControlsTextSelected(trackId));
      await bloc.stream.firstWhere((s) => s.activePanel == PlayerPanel.none);
    }

    // Off on a film that started off changes nothing.
    await pick(null);
    await pick(1);
    await pick(null);
    p.selectionSucceeds = false;
    await pick(1);

    expect(bloc.state.selectedTextTrackId, isNull);
    expect(languages, <String?>['de', null]);
    await bloc.close();
  });

  test(
    'a remembered subtitle applied on load is not a viewer switch',
    () async {
      final languages = <String?>[];
      final store = SubtitlePreferenceStore()..remember('en');
      final bloc = _bloc(store: store, onSubtitleTrackChanged: languages.add);
      bloc.add(
        const PlayerControlsTracksLoaded(
          audioTracks: <PlayerAudioTrack>[],
          textTracks: <PlayerTextTrack>[
            PlayerTextTrack(trackId: 2, language: 'en'),
          ],
        ),
      );
      await bloc.stream.first;

      expect(bloc.state.selectedTextTrackId, 2);
      expect(languages, isEmpty);
      await bloc.close();
    },
  );

  test('a viewer-requested hide dismisses the panel with the overlay', () {
    fakeAsync((async) {
      final bloc = _bloc();
      bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
      async.flushMicrotasks();
      bloc.add(const PlayerControlsHideRequested());
      async.flushMicrotasks();

      expect(bloc.state.activePanel, PlayerPanel.none);
      expect(bloc.state.visible, isFalse);
      bloc.close();
    });
  });
}

/// One fake wearing both hats: playback commands and track selection.
final class _FakePlayback
    implements VideoplaybackController, VideoplaybackTracks {
  int playCount = 0;
  int pauseCount = 0;
  Duration? lastSeek;
  int? lastTextSelection;
  bool textSelectionCleared = false;

  /// What the native player answers to a selection. `false` is a real TV
  /// failure mode — a firmware that refuses the switch.
  bool selectionSucceeds = true;

  @override
  VideoplaybackValue get value => const VideoplaybackValue();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  /// Every seek handed to the native side, and whether two ever overlapped —
  /// which PlusPlayer refuses.
  final List<Duration> seeks = <Duration>[];
  bool seekOverlapped = false;
  bool _seeking = false;
  Duration seekLatency = Duration.zero;

  @override
  Future<void> seekTo(Duration position) async {
    if (_seeking) seekOverlapped = true;
    _seeking = true;
    seeks.add(position);
    lastSeek = position;
    if (seekLatency > Duration.zero) await Future<void>.delayed(seekLatency);
    _seeking = false;
  }

  @override
  void addListener(void Function(VideoplaybackValue) listener) {}

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {}

  @override
  Future<void> dispose() async {}

  @override
  int? selectedAudioTrackId;

  @override
  int? selectedTextTrackId;

  @override
  Future<List<PlayerAudioTrack>> audioTracks() async =>
      const <PlayerAudioTrack>[];

  @override
  Future<List<PlayerTextTrack>> textTracks() async => const <PlayerTextTrack>[];

  @override
  Future<bool> selectAudioTrack(int trackId) async {
    if (!selectionSucceeds) return false;
    selectedAudioTrackId = trackId;
    return true;
  }

  @override
  Future<bool> selectTextTrack(int? trackId) async {
    if (!selectionSucceeds) return false;
    if (trackId == null) {
      textSelectionCleared = true;
      selectedTextTrackId = null;
    } else {
      lastTextSelection = trackId;
      selectedTextTrackId = trackId;
    }
    return true;
  }
}
