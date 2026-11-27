part of 'player_controls_bloc.dart';

@immutable
sealed class PlayerControlsEvent {
  const PlayerControlsEvent();
}

/// Any user input (remote key, tap). Wakes the overlay and resets the timer.
final class PlayerControlsActivity extends PlayerControlsEvent {
  const PlayerControlsActivity();
}

/// Dismiss the overlay, closing any open track panel with it.
///
/// [idleGeneration] is set only by the auto-hide timer, and names the timer
/// that fired. A timer cancelled after it had already queued this event is
/// stale: its generation no longer matches, and the hide is dropped rather
/// than landing on whatever the viewer did in between. A viewer-requested
/// dismiss leaves it `null` and is always honoured.
final class PlayerControlsHideRequested extends PlayerControlsEvent {
  const PlayerControlsHideRequested({this.idleGeneration});

  final int? idleGeneration;
}

final class PlayerControlsPanelOpened extends PlayerControlsEvent {
  const PlayerControlsPanelOpened(this.panel);

  final PlayerPanel panel;
}

final class PlayerControlsPanelClosed extends PlayerControlsEvent {
  const PlayerControlsPanelClosed();
}

final class PlayerControlsValueTicked extends PlayerControlsEvent {
  const PlayerControlsValueTicked({
    required this.position,
    required this.duration,
    required this.isPlaying,
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
}

final class PlayerControlsBufferingChanged extends PlayerControlsEvent {
  const PlayerControlsBufferingChanged(this.isBuffering);

  final bool isBuffering;
}

final class PlayerControlsTracksLoaded extends PlayerControlsEvent {
  const PlayerControlsTracksLoaded({
    required this.audioTracks,
    required this.textTracks,
    this.forcedTextTracks = const <PlayerTextTrack>[],
  });

  final List<PlayerAudioTrack> audioTracks;

  /// The subtitle tracks the menu offers.
  final List<PlayerTextTrack> textTracks;

  /// Forced subtitle tracks (HLS `FORCED=YES`): never in the menu, played
  /// while subtitles are off.
  final List<PlayerTextTrack> forcedTextTracks;
}

final class PlayerControlsPlayPauseToggled extends PlayerControlsEvent {
  const PlayerControlsPlayPauseToggled();
}

/// OK on the focused seek bar. Seeks at once to an open skip burst's
/// preview; with no burst open, toggles play/pause.
final class PlayerControlsSeekBarActivated extends PlayerControlsEvent {
  const PlayerControlsSeekBarActivated();
}

/// Positive [steps] = forward, negative = backward; multiplied by the skip
/// step (default 15 s).
final class PlayerControlsSkipBy extends PlayerControlsEvent {
  const PlayerControlsSkipBy(this.steps, {this.fromSkipButton = false});

  final int steps;

  /// Pressed on the middle back or forward button, which then stays on
  /// screen; any other skip (seek bar, remote) clears the middle of the
  /// picture while it previews.
  final bool fromSkipButton;
}

/// The skip burst is over: seek once to where it left the preview.
final class _PlayerControlsSkipCommitted extends PlayerControlsEvent {
  const _PlayerControlsSkipCommitted();
}

final class PlayerControlsSeekRequested extends PlayerControlsEvent {
  const PlayerControlsSeekRequested(this.position);

  final Duration position;
}

final class PlayerControlsScrubStarted extends PlayerControlsEvent {
  const PlayerControlsScrubStarted();
}

final class PlayerControlsScrubEnded extends PlayerControlsEvent {
  const PlayerControlsScrubEnded(this.position);

  final Duration position;
}

final class PlayerControlsAudioSelected extends PlayerControlsEvent {
  const PlayerControlsAudioSelected(this.trackId);

  final int trackId;
}

final class PlayerControlsTextSelected extends PlayerControlsEvent {
  const PlayerControlsTextSelected(this.trackId);

  /// `null` clears subtitles.
  final int? trackId;
}
