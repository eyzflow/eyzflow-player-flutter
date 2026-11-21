import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import '../player/playback_target.dart';

part 'videoplayer_feature_event.dart';
part 'videoplayer_feature_state.dart';

class VideoplayerFeatureBloc
    extends Bloc<VideoplayerFeatureEvent, VideoplayerFeatureState> {
  VideoplayerFeatureBloc({required VideoplayerTarget target})
    : super(VideoplayerFeatureState(target: target)) {
    on<VideoplayerFeatureStarted>(_onStarted);
    on<VideoplayerFeaturePictureInPictureChanged>((event, emit) {
      emit(state.copyWith(isPictureInPicture: event.enabled));
    });
    on<VideoplayerFeatureRetryRequested>((event, emit) {
      if (state.featureState != VideoplayerFeatureStatus.failed) return;
      emit(
        state.copyWith(
          featureState: VideoplayerFeatureStatus.ready,
          errorMessage: null,
          isPictureInPicture: false,
        ),
      );
    });
    on<VideoplayerFeaturePlaybackFinished>(_onPlaybackFinished);
    on<VideoplayerFeaturePlayerFailed>(_onPlayerFailed);
    on<VideoplayerFeatureSourceFailed>(_onSourceFailed);
  }

  void _onStarted(
    VideoplayerFeatureStarted event,
    Emitter<VideoplayerFeatureState> emit,
  ) {
    emit(
      state.copyWith(
        featureState: VideoplayerFeatureStatus.ready,
        errorMessage: null,
      ),
    );
  }

  void _onPlaybackFinished(
    VideoplayerFeaturePlaybackFinished event,
    Emitter<VideoplayerFeatureState> emit,
  ) {
    emit(state.copyWith(featureState: VideoplayerFeatureStatus.finished));
  }

  void _onPlayerFailed(
    VideoplayerFeaturePlayerFailed event,
    Emitter<VideoplayerFeatureState> emit,
  ) {
    emit(
      state.copyWith(
        featureState: VideoplayerFeatureStatus.failed,
        isPictureInPicture: false,
        errorMessage: event.message,
      ),
    );
  }

  void _onSourceFailed(
    VideoplayerFeatureSourceFailed event,
    Emitter<VideoplayerFeatureState> emit,
  ) {
    emit(
      state.copyWith(
        featureState: VideoplayerFeatureStatus.failed,
        isPictureInPicture: false,
        errorMessage: event.message,
      ),
    );
  }
}
