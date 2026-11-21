import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import '../l10n/language_names.dart';
import 'package:flutter/foundation.dart';

import '../player/player_log.dart';
import '../player/player_policy.dart';
import '../player/subtitle_preference_store.dart';

part 'player_controls_event.dart';
part 'player_controls_state.dart';

/// Skip size for the ±15 s buttons, matching the `replay_15`/`forward_15`
/// icons the overlay renders.
const Duration kPlayerSkipStep = Duration(seconds: 15);

/// How long the overlay stays visible after the last input.
const Duration kPlayerAutoHide = Duration(seconds: 4);

/// How long a skip burst waits for another press before it seeks.
const Duration kPlayerSkipCommitDelay = Duration(milliseconds: 600);

/// Drives the TV player controls overlay: owns the auto-hide timer, the
/// track lists, and the two selected ids, and delegates every side effect to
/// [VideoplaybackController] + [VideoplaybackTracks]. Remembers subtitle
/// language across films through [SubtitlePreferenceStore] when one exists.
class PlayerControlsBloc
    extends Bloc<PlayerControlsEvent, PlayerControlsState> {
  PlayerControlsBloc({
    required VideoplaybackController controller,
    required VideoplaybackTracks tracks,
    SubtitlePreferenceStore? subtitlePreferenceStore,
    this.autoHide = kPlayerAutoHide,
    this.hidesWhenIdle = true,
    this.captions = true,
    this.skipStep = kPlayerSkipStep,
    this.skipCommitDelay = kPlayerSkipCommitDelay,
    this.onSeeked,
    this.onAudioTrackChanged,
    this.onSubtitleTrackChanged,
  }) : _controller = controller, // ignore: prefer_initializing_formals
       _tracks = tracks, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _subtitlePreferenceStore = subtitlePreferenceStore,
       super(const PlayerControlsState()) {
    on<PlayerControlsActivity>(_onActivity);
    on<PlayerControlsHideRequested>(_onHideRequested);
    on<PlayerControlsPanelOpened>(_onPanelOpened);
    on<PlayerControlsPanelClosed>(_onPanelClosed);
    on<PlayerControlsValueTicked>(_onValueTicked);
    on<PlayerControlsBufferingChanged>(_onBufferingChanged);
    on<PlayerControlsTracksLoaded>(_onTracksLoaded);
    on<PlayerControlsPlayPauseToggled>(_onPlayPauseToggled);
    on<PlayerControlsSkipBy>(_onSkipBy);
    on<_PlayerControlsSkipCommitted>(_onSkipCommitted);
    on<PlayerControlsSeekRequested>(_onSeekRequested);
    on<PlayerControlsScrubStarted>(_onScrubStarted);
    on<PlayerControlsScrubEnded>(_onScrubEnded);
    on<PlayerControlsAudioSelected>(_onAudioSelected);
    on<PlayerControlsTextSelected>(_onTextSelected);
  }

  final VideoplaybackController _controller;
  final VideoplaybackTracks _tracks;
  final SubtitlePreferenceStore? _subtitlePreferenceStore;
  final Duration autoHide;

  /// False keeps the overlay up while the viewer is idle (a player config's
  /// `autoHideControls`). Back still hides it.
  final bool hidesWhenIdle;

  /// False plays without subtitles and offers none (a player config's
  /// `captions`): the track list stays empty and a remembered subtitle
  /// language is not applied.
  final bool captions;
  final Duration skipStep;

  /// Skips only move the shown position; one seek follows this long after
  /// the last press. Every native seek makes the player drop its buffer and
  /// load from the new spot, so seeking on each press (and on each key
  /// repeat while Left/Right is held on the progress bar) kept restarting
  /// the loading. [Duration.zero] seeks on every press.
  final Duration skipCommitDelay;

  /// Where the current skip burst has moved the preview, and where playback
  /// was when it began. Null outside a burst.
  Duration? _skipPreview;
  Duration? _skipFrom;
  var _skipPresses = 0;
  Timer? _skipTimer;

  /// Told about each seek as it is handed to the controller — a skip, a
  /// scrub, a seek request — with where playback was and where it was sent.
  /// A burst collapsed by [_seek] reports the seeks that were issued, not the
  /// presses. Plain callbacks rather than a listener type, so the Bloc knows
  /// nothing about who is counting: the player widgets point these at their
  /// playback events.
  final void Function(Duration from, Duration to)? onSeeked;

  /// Told the language of the audio track the viewer switched to, once the
  /// native player has accepted it. Not called for a refused switch, nor for
  /// OK on the row already playing.
  final void Function(String? language)? onAudioTrackChanged;

  /// Told the language of the subtitle track the viewer switched to, or
  /// `null` for off, under the same rules as [onAudioTrackChanged]. The track
  /// applied from a remembered preference when tracks load is not the viewer
  /// switching, and is not reported.
  final void Function(String? language)? onSubtitleTrackChanged;

  Timer? _hideTimer;

  /// Bumped every time the countdown restarts, so a timeout queued by a timer
  /// that has since been replaced can be told apart from the current one.
  int _hideGeneration = 0;

  /// The newest seek target not yet handed to the controller, where playback
  /// was when the first of the presses it stands for arrived, and the drain
  /// loop applying them. See [_seek].
  Duration? _pendingSeek;
  Duration? _pendingSeekFrom;
  Future<void>? _seekDrain;

  @override
  Future<void> close() {
    _hideTimer?.cancel();
    _skipTimer?.cancel();
    return super.close();
  }

  void _onActivity(
    PlayerControlsActivity event,
    Emitter<PlayerControlsState> emit,
  ) {
    emit(state.copyWith(visible: true));
    _restartHideTimer();
  }

  void _onHideRequested(
    PlayerControlsHideRequested event,
    Emitter<PlayerControlsState> emit,
  ) {
    // An in-flight drag owns the screen: hiding under it would yank the UI
    // out from under the viewer.
    if (state.isScrubbing) return;
    // A timer that was restarted after queueing this event has been overtaken
    // by something the viewer did; dropping it stops a stale timeout landing
    // on the newer state.
    final int? generation = event.idleGeneration;
    if (generation != null && generation != _hideGeneration) return;
    _hideTimer?.cancel();
    // The overlay always comes back in its resting state: no panel open, and
    // the view restores focus to the transport.
    emit(state.copyWith(visible: false, activePanel: PlayerPanel.none));
  }

  void _onPanelOpened(
    PlayerControlsPanelOpened event,
    Emitter<PlayerControlsState> emit,
  ) {
    emit(state.copyWith(visible: true, activePanel: event.panel));
    // Opening a panel is input like any other: it restarts the countdown
    // rather than suspending it. An idle viewer loses the whole overlay,
    // panel included.
    _restartHideTimer();
  }

  void _onPanelClosed(
    PlayerControlsPanelClosed event,
    Emitter<PlayerControlsState> emit,
  ) {
    emit(state.copyWith(activePanel: PlayerPanel.none));
    _restartHideTimer();
  }

  void _onValueTicked(
    PlayerControlsValueTicked event,
    Emitter<PlayerControlsState> emit,
  ) {
    // While the viewer drags, the slider owns the position — playback ticks
    // would fight it. So does a skip burst's preview until its seek is sent.
    if (state.isScrubbing || _skipPreview != null) {
      emit(
        state.copyWith(duration: event.duration, isPlaying: event.isPlaying),
      );
      return;
    }
    emit(
      state.copyWith(
        position: event.position,
        duration: event.duration,
        isPlaying: event.isPlaying,
      ),
    );
  }

  void _onBufferingChanged(
    PlayerControlsBufferingChanged event,
    Emitter<PlayerControlsState> emit,
  ) {
    emit(state.copyWith(isBuffering: event.isBuffering));
  }

  void _onTracksLoaded(
    PlayerControlsTracksLoaded event,
    Emitter<PlayerControlsState> emit,
  ) {
    if (!captions) {
      unawaited(_tracks.selectTextTrack(null));
      emit(
        state.copyWith(
          audioTracks: event.audioTracks,
          textTracks: const <PlayerTextTrack>[],
          selectedAudioTrackId: _tracks.selectedAudioTrackId,
          clearSelectedTextTrackId: true,
        ),
      );
      return;
    }
    int? selectedText = _tracks.selectedTextTrackId;

    final SubtitlePreferenceStore? store = _subtitlePreferenceStore;
    if (store != null && store.hasPreference) {
      final String? preferred = store.languageCode;
      if (preferred == null) {
        selectedText = null;
        unawaited(_tracks.selectTextTrack(null));
      } else {
        // Matched on the resolved display name, not the raw code: EYZFlow
        // tags the same language differently across streams (`deu` here,
        // `de` there, `de_DE` elsewhere), and a raw comparison lost the
        // preference on the next film. A `null` name means the remembered
        // code names no determinate language, which no panel row can
        // produce — treated as no match rather than matching the `und`
        // tracks, whose names are also null.
        final String? preferredName = EyzflowLanguageNames.languageName(
          preferred,
        );
        final PlayerTextTrack? match = preferredName == null
            ? null
            : event.textTracks.cast<PlayerTextTrack?>().firstWhere(
                (PlayerTextTrack? t) =>
                    t != null &&
                    EyzflowLanguageNames.languageName(t.language) ==
                        preferredName,
                orElse: () => null,
              );
        // Product rule: no match means nothing selected, not the plugin
        // default.
        selectedText = match?.trackId;
        unawaited(_tracks.selectTextTrack(match?.trackId));
      }
    }

    emit(
      state.copyWith(
        audioTracks: event.audioTracks,
        textTracks: event.textTracks,
        selectedAudioTrackId: _tracks.selectedAudioTrackId,
        selectedTextTrackId: selectedText,
        clearSelectedTextTrackId: selectedText == null,
      ),
    );
  }

  Future<void> _onPlayPauseToggled(
    PlayerControlsPlayPauseToggled event,
    Emitter<PlayerControlsState> emit,
  ) async {
    emit(state.copyWith(visible: true));
    if (state.isPlaying) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
    _restartHideTimer();
  }

  Future<void> _onSkipBy(
    PlayerControlsSkipBy event,
    Emitter<PlayerControlsState> emit,
  ) async {
    if (skipCommitDelay == Duration.zero) {
      final Duration from = state.position;
      final Duration target = _clamp(
        from + (skipStep * event.steps),
        state.duration,
      );
      emit(state.copyWith(visible: true, position: target));
      await _seek(target, from: from);
      _restartHideTimer();
      return;
    }
    final Duration from = _skipPreview ?? state.position;
    _skipFrom ??= state.position;
    _skipPresses += 1;
    // Holding Left/Right speeds up: 15 s steps, then 30 s, then 60 s.
    final int speed = _skipPresses > 10 ? 4 : (_skipPresses > 4 ? 2 : 1);
    final Duration target = _clamp(
      from + (skipStep * (event.steps * speed)),
      state.duration,
    );
    _skipPreview = target;
    emit(state.copyWith(visible: true, position: target, isPreviewing: true));
    _skipTimer?.cancel();
    // The overlay stays up while the burst is open.
    _hideTimer?.cancel();
    _skipTimer = Timer(skipCommitDelay, () {
      if (!isClosed) add(const _PlayerControlsSkipCommitted());
    });
  }

  Future<void> _onSkipCommitted(
    _PlayerControlsSkipCommitted event,
    Emitter<PlayerControlsState> emit,
  ) async {
    final Future<void> seek = _commitSkip();
    // The seek is with the player: the preview (and its thumbnail) is over.
    emit(state.copyWith(isPreviewing: false));
    await seek;
  }

  /// An explicit seek or a drag takes over from an open skip burst.
  void _dropSkipBurst() {
    _skipTimer?.cancel();
    _skipTimer = null;
    _skipPreview = null;
    _skipFrom = null;
    _skipPresses = 0;
  }

  /// Seeks once to where the skip burst left the preview.
  Future<void> _commitSkip() async {
    final Duration? target = _skipPreview;
    final Duration? from = _skipFrom;
    _skipTimer?.cancel();
    _skipTimer = null;
    _skipPresses = 0;
    if (target == null) return;
    try {
      await _seek(target, from: from ?? target);
    } finally {
      // Ticks follow playback again once the seek is with the player.
      _skipPreview = null;
      _skipFrom = null;
      _restartHideTimer();
    }
  }

  Future<void> _onSeekRequested(
    PlayerControlsSeekRequested event,
    Emitter<PlayerControlsState> emit,
  ) async {
    _dropSkipBurst();
    final Duration from = state.position;
    final Duration target = _clamp(event.position, state.duration);
    emit(state.copyWith(visible: true, position: target, isPreviewing: false));
    await _seek(target, from: from);
    _restartHideTimer();
  }

  void _onScrubStarted(
    PlayerControlsScrubStarted event,
    Emitter<PlayerControlsState> emit,
  ) {
    _dropSkipBurst();
    _hideTimer?.cancel();
    final bool wasPlaying = state.isPlaying;
    emit(
      state.copyWith(
        isScrubbing: true,
        isPreviewing: false,
        wasPlayingBeforeScrub: wasPlaying,
        // Optimistic: we're about to call pause() below, so reflect it
        // immediately rather than waiting on the controller's next tick.
        isPlaying: false,
        visible: true,
      ),
    );
    if (wasPlaying) unawaited(_controller.pause());
  }

  Future<void> _onScrubEnded(
    PlayerControlsScrubEnded event,
    Emitter<PlayerControlsState> emit,
  ) async {
    final bool resume = state.wasPlayingBeforeScrub;
    final Duration target = _clamp(event.position, state.duration);
    // Seek (and resume) before emitting: the state broadcast is async, so an
    // emit ahead of a second awaited controller call can reach listeners
    // before that call has actually run — same ordering the audio/text
    // selection handlers below rely on. The unstick emit still has to run on
    // a controller failure (DRM/network drop is a real TV failure mode),
    // so it — and restarting the hide timer — lives in `finally`.
    try {
      // Ticks do not move the position during a drag, so this is still where
      // the scrub began.
      await _seek(target, from: state.position);
      if (resume) await _controller.play();
    } finally {
      emit(state.copyWith(isScrubbing: false, position: target));
      _restartHideTimer();
    }
  }

  Future<void> _onAudioSelected(
    PlayerControlsAudioSelected event,
    Emitter<PlayerControlsState> emit,
  ) async {
    // OK on the row that is already checked is a dismissal, not a switch, so
    // the native call is skipped: re-selecting the running track is a real
    // operation on a TV and can glitch the audio for a beat.
    final bool isSwitch = state.selectedAudioTrackId != event.trackId;
    final bool ok = !isSwitch || await _tracks.selectAudioTrack(event.trackId);
    if (ok && isSwitch) {
      onAudioTrackChanged?.call(
        state.audioTracks
            .cast<PlayerAudioTrack?>()
            .firstWhere(
              (PlayerAudioTrack? t) => t?.trackId == event.trackId,
              orElse: () => null,
            )
            ?.language,
      );
    }
    // The panel closes either way. A viewer who pressed OK is done with the
    // sidebar, and a native refusal used to leave them holding one that
    // answered nothing; `null` keeps the current id, so the unmoved checkmark
    // is what says the switch did not take.
    emit(
      state.copyWith(
        selectedAudioTrackId: ok ? event.trackId : null,
        activePanel: PlayerPanel.none,
      ),
    );
    _restartHideTimer();
  }

  Future<void> _onTextSelected(
    PlayerControlsTextSelected event,
    Emitter<PlayerControlsState> emit,
  ) async {
    // Same short-circuit as the audio panel — but the preference is still
    // recorded below: pressing Off on a film that started off is how a viewer
    // says "and keep it off", and there is no selection change to infer it
    // from.
    final bool isSwitch = state.selectedTextTrackId != event.trackId;
    final bool ok = !isSwitch || await _tracks.selectTextTrack(event.trackId);

    final PlayerTextTrack? track = state.textTracks
        .cast<PlayerTextTrack?>()
        .firstWhere(
          (PlayerTextTrack? t) => t?.trackId == event.trackId,
          orElse: () => null,
        );
    final SubtitlePreferenceStore? store = ok ? _subtitlePreferenceStore : null;
    if (store != null) {
      if (event.trackId == null) {
        store.rememberOff();
      } else if (track != null) {
        store.remember(track.language);
      }
    }
    if (ok && isSwitch) {
      // `null` means off to whoever is listening, so a track the list does
      // not know is reported as undetermined rather than as nothing.
      onSubtitleTrackChanged?.call(
        event.trackId == null ? null : track?.language ?? 'und',
      );
    }

    emit(
      state.copyWith(
        selectedTextTrackId: ok ? event.trackId : null,
        clearSelectedTextTrackId: ok && event.trackId == null,
        activePanel: PlayerPanel.none,
      ),
    );
    _restartHideTimer();
  }

  /// Serialises seeks, collapsing a burst to its last target.
  ///
  /// Bloc runs these handlers concurrently, so repeated ±15 s presses used to
  /// overlap native seeks. PlusPlayer refuses a seek while one is in flight
  /// ("Player is already seeking") and the plugin surfaces that as a thrown
  /// `PlatformException`, which left playback wedged mid-seek. Each caller's
  /// future completes once the latest target has been applied, so a scrub's
  /// resume still lands after its seek. A refused seek is logged, not
  /// rethrown: the next input simply seeks again.
  ///
  /// [onSeeked] hears of each seek before it is issued rather than once it
  /// lands: the position starts moving while the native call is still in
  /// flight, and whoever infers seeks from the position has to know by then
  /// that this one was asked for.
  Future<void> _seek(Duration target, {required Duration from}) {
    _pendingSeek = target;
    _pendingSeekFrom ??= from;
    return _seekDrain ??= () async {
      try {
        for (Duration? next = _pendingSeek; next != null; next = _pendingSeek) {
          final Duration origin = _pendingSeekFrom ?? next;
          _pendingSeek = null;
          _pendingSeekFrom = null;
          // A skip clamped at either end goes nowhere; that is not a seek.
          if (origin != next) onSeeked?.call(origin, next);
          try {
            await _controller.seekTo(next);
          } on Object catch (error) {
            logPlayback(
              'seek to ${next.inMilliseconds}ms failed',
              error: error,
            );
          }
        }
      } finally {
        _seekDrain = null;
      }
    }();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // A drag is the one thing that suspends the countdown outright: the
    // viewer is holding the UI. An open panel keeps counting down.
    if (state.isScrubbing || !hidesWhenIdle) return;
    final int generation = ++_hideGeneration;
    _hideTimer = Timer(autoHide, () {
      if (!isClosed) {
        add(PlayerControlsHideRequested(idleGeneration: generation));
      }
    });
  }

  Duration _clamp(Duration position, Duration duration) {
    if (position < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }
}
