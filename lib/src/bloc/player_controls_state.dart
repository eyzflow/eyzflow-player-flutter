part of 'player_controls_bloc.dart';

enum PlayerPanel { none, audio, subtitles }

@immutable
final class PlayerControlsState extends Equatable {
  const PlayerControlsState({
    this.visible = true,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isScrubbing = false,
    this.wasPlayingBeforeScrub = false,
    this.isPreviewing = false,
    this.previewFromSkipButton = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.audioTracks = const <PlayerAudioTrack>[],
    this.textTracks = const <PlayerTextTrack>[],
    this.selectedAudioTrackId,
    this.selectedTextTrackId,
    this.forcedTextTracks = const <PlayerTextTrack>[],
    this.forcedTextTrackId,
    this.activePanel = PlayerPanel.none,
  });

  final bool visible;
  final bool isPlaying;
  final bool isBuffering;
  final bool isScrubbing;
  final bool wasPlayingBeforeScrub;

  /// A skip burst is open: [position] is where it will seek, not where
  /// playback is. The overlay shows the thumbnail of that point.
  final bool isPreviewing;

  /// The open skip burst came from the middle back or forward button.
  final bool previewFromSkipButton;
  final Duration position;
  final Duration duration;
  final List<PlayerAudioTrack> audioTracks;
  final List<PlayerTextTrack> textTracks;
  final int? selectedAudioTrackId;
  final int? selectedTextTrackId;

  /// Forced subtitle tracks (only the lines in another language than the
  /// audio). Never offered in the menu.
  final List<PlayerTextTrack> forcedTextTracks;

  /// The forced track playing while subtitles are off ([selectedTextTrackId]
  /// null): the one in the audio's language. Null when there is none, or
  /// while full subtitles are on.
  final int? forcedTextTrackId;
  final PlayerPanel activePanel;

  /// The viewer is looking for a frame: the back, play/pause and forward
  /// buttons under the seek bar step aside so only the bar and its thumbnail
  /// hold the eye.
  bool get hidesMiddleRow =>
      isScrubbing || (isPreviewing && !previewFromSkipButton);

  PlayerControlsState copyWith({
    bool? visible,
    bool? isPlaying,
    bool? isBuffering,
    bool? isScrubbing,
    bool? wasPlayingBeforeScrub,
    bool? isPreviewing,
    bool? previewFromSkipButton,
    Duration? position,
    Duration? duration,
    List<PlayerAudioTrack>? audioTracks,
    List<PlayerTextTrack>? textTracks,
    int? selectedAudioTrackId,
    int? selectedTextTrackId,
    // `selectedTextTrackId` is nullable, so copyWith needs an explicit way to
    // set it to null: pass `clearSelectedTextTrackId: true`.
    bool clearSelectedTextTrackId = false,
    List<PlayerTextTrack>? forcedTextTracks,
    int? forcedTextTrackId,
    bool clearForcedTextTrackId = false,
    PlayerPanel? activePanel,
  }) => PlayerControlsState(
    visible: visible ?? this.visible,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    isScrubbing: isScrubbing ?? this.isScrubbing,
    wasPlayingBeforeScrub: wasPlayingBeforeScrub ?? this.wasPlayingBeforeScrub,
    isPreviewing: isPreviewing ?? this.isPreviewing,
    previewFromSkipButton: previewFromSkipButton ?? this.previewFromSkipButton,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    audioTracks: audioTracks ?? this.audioTracks,
    textTracks: textTracks ?? this.textTracks,
    selectedAudioTrackId: selectedAudioTrackId ?? this.selectedAudioTrackId,
    selectedTextTrackId: clearSelectedTextTrackId
        ? null
        : (selectedTextTrackId ?? this.selectedTextTrackId),
    forcedTextTracks: forcedTextTracks ?? this.forcedTextTracks,
    forcedTextTrackId: clearForcedTextTrackId
        ? null
        : (forcedTextTrackId ?? this.forcedTextTrackId),
    activePanel: activePanel ?? this.activePanel,
  );

  @override
  List<Object?> get props => <Object?>[
    visible,
    isPlaying,
    isBuffering,
    isScrubbing,
    wasPlayingBeforeScrub,
    isPreviewing,
    previewFromSkipButton,
    position,
    duration,
    audioTracks,
    textTracks,
    selectedAudioTrackId,
    selectedTextTrackId,
    forcedTextTracks,
    forcedTextTrackId,
    activePanel,
  ];
}
