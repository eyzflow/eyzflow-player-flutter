part of 'videoplayer_feature_bloc.dart';

@immutable
sealed class VideoplayerFeatureEvent {
  const VideoplayerFeatureEvent();
}

final class VideoplayerFeatureStarted extends VideoplayerFeatureEvent {
  const VideoplayerFeatureStarted();
}

final class VideoplayerFeaturePlaybackFinished extends VideoplayerFeatureEvent {
  const VideoplayerFeaturePlaybackFinished();
}

final class VideoplayerFeaturePlayerFailed extends VideoplayerFeatureEvent {
  const VideoplayerFeaturePlayerFailed(this.message);

  final String message;
}

final class VideoplayerFeatureSourceFailed extends VideoplayerFeatureEvent {
  const VideoplayerFeatureSourceFailed(this.message);

  final String message;
}

final class VideoplayerFeaturePictureInPictureChanged
    extends VideoplayerFeatureEvent {
  const VideoplayerFeaturePictureInPictureChanged(this.enabled);
  final bool enabled;
}

final class VideoplayerFeatureRetryRequested extends VideoplayerFeatureEvent {
  const VideoplayerFeatureRetryRequested();
}
