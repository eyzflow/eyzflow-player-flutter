part of 'videoplayer_feature_bloc.dart';

enum VideoplayerFeatureStatus { loading, ready, finished, failed }

@immutable
final class VideoplayerFeatureState extends Equatable {
  const VideoplayerFeatureState({
    required this.target,
    this.featureState = VideoplayerFeatureStatus.loading,
    this.errorMessage,
    this.isPictureInPicture = false,
  });

  final VideoplayerTarget target;
  final VideoplayerFeatureStatus featureState;
  final String? errorMessage;
  final bool isPictureInPicture;

  VideoplayerFeatureState copyWith({
    VideoplayerTarget? target,
    VideoplayerFeatureStatus? featureState,
    Object? errorMessage = _noChange,
    bool? isPictureInPicture,
  }) {
    return VideoplayerFeatureState(
      target: target ?? this.target,
      isPictureInPicture: isPictureInPicture ?? this.isPictureInPicture,
      featureState: featureState ?? this.featureState,
      errorMessage: identical(errorMessage, _noChange)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  static const Object _noChange = Object();

  @override
  List<Object?> get props => [
    target,
    featureState,
    errorMessage,
    isPictureInPicture,
  ];
}
