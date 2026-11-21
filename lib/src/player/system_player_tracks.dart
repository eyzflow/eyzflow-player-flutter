import '../native/native_video_player.dart';

import 'player_policy.dart';

/// Maps the native player's audio tracks onto the package's
/// plugin-agnostic type. The plugin's `index` is the `trackId`: it is what
/// `setAudioTrack` addresses, so nothing else needs inventing.
List<PlayerAudioTrack> systemAudioTracks(
  List<NativeVideoPlayerAudioTrack> tracks,
) => <PlayerAudioTrack>[
  for (final NativeVideoPlayerAudioTrack track in tracks)
    PlayerAudioTrack(trackId: track.index, language: track.language),
];

/// Maps the plugin's subtitle tracks. Both embedded and sidecar sources come
/// through here — the overlay treats them alike, and the plugin's
/// `setSubtitleTrack` dispatches on the track's own `source`.
List<PlayerTextTrack> systemTextTracks(
  List<NativeVideoPlayerSubtitleTrack> tracks,
) => <PlayerTextTrack>[
  for (final NativeVideoPlayerSubtitleTrack track in tracks)
    PlayerTextTrack(trackId: track.index, language: track.language),
];

/// The index the plugin reports as already selected, or `null` when nothing is
/// flagged — which the overlay renders as "no selection", never as a silent
/// default.
int? systemSelectedIndex<T>(
  List<T> tracks,
  bool Function(T) isSelected,
  int Function(T) indexOf,
) {
  for (final T track in tracks) {
    if (isSelected(track)) return indexOf(track);
  }
  return null;
}
