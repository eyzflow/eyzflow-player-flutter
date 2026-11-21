import 'package:equatable/equatable.dart';
import '../core/source.dart';

/// What the player has been asked to play.
///
/// Pure data: no plugin type, no widget, no platform check.
sealed class VideoplayerTarget extends Equatable {
  const VideoplayerTarget();
}

/// A real trailer, described by an EYZFlow-derived source.
final class VideoplayerTrailerTarget extends VideoplayerTarget {
  const VideoplayerTrailerTarget(this.source);

  final EyzflowSource source;

  @override
  List<Object?> get props => <Object?>[source];
}

/// A full-film or episode source with its own DRM credential.
///
/// Kept distinct from [VideoplayerTrailerTarget] so the type itself says
/// which sources carry a real Widevine license request — a trailer target is
/// never DRM-protected, so nothing has to inspect
/// [EyzflowSource.sourceType] at the player layer to know that.
final class VideoplayerSourceTarget extends VideoplayerTarget {
  const VideoplayerSourceTarget(this.source);

  final EyzflowSource source;

  @override
  List<Object?> get props => <Object?>[source];
}
