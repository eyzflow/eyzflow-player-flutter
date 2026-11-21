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
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.audioTracks = const <PlayerAudioTrack>[],
    this.textTracks = const <PlayerTextTrack>[],
    this.selectedAudioTrackId,
    this.selectedTextTrackId,
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
  final Duration position;
  final Duration duration;
  final List<PlayerAudioTrack> audioTracks;
  final List<PlayerTextTrack> textTracks;
  final int? selectedAudioTrackId;
  final int? selectedTextTrackId;
  final PlayerPanel activePanel;

  PlayerControlsState copyWith({
    bool? visible,
    bool? isPlaying,
    bool? isBuffering,
    bool? isScrubbing,
    bool? wasPlayingBeforeScrub,
    bool? isPreviewing,
    Duration? position,
    Duration? duration,
    List<PlayerAudioTrack>? audioTracks,
    List<PlayerTextTrack>? textTracks,
    int? selectedAudioTrackId,
    int? selectedTextTrackId,
    // `selectedTextTrackId` is nullable, so copyWith needs an explicit way to
    // set it to null: pass `clearSelectedTextTrackId: true`.
    bool clearSelectedTextTrackId = false,
    PlayerPanel? activePanel,
  }) => PlayerControlsState(
    visible: visible ?? this.visible,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    isScrubbing: isScrubbing ?? this.isScrubbing,
    wasPlayingBeforeScrub: wasPlayingBeforeScrub ?? this.wasPlayingBeforeScrub,
    isPreviewing: isPreviewing ?? this.isPreviewing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    audioTracks: audioTracks ?? this.audioTracks,
    textTracks: textTracks ?? this.textTracks,
    selectedAudioTrackId: selectedAudioTrackId ?? this.selectedAudioTrackId,
    selectedTextTrackId: clearSelectedTextTrackId
        ? null
        : (selectedTextTrackId ?? this.selectedTextTrackId),
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
    position,
    duration,
    audioTracks,
    textTracks,
    selectedAudioTrackId,
    selectedTextTrackId,
    activePanel,
  ];
}
