import 'package:flutter/material.dart';

import 'no_player_surface.dart';
import 'platform_detector.dart';
import 'playback_event.dart';
import 'playback_target.dart';
import 'player_options.dart';
import 'player_policy.dart';
import 'system_video_player.dart';
import 'tizen_avplay_player.dart';
import 'watch_progress_recorder.dart';

Widget buildDefaultVideoplayerPlayer(
  BuildContext context,
  VideoplayerTarget target, {
  String? operatingSystem,
  bool isTv = false,
  WatchProgressRecorder? watchProgressRecorder,
  PlaybackEventCallback? onPlaybackEvent,
  bool castAvailable = false,
  void Function(Duration position)? onCastRequested,
  PlayerOptions options = const PlayerOptions(),
}) {
  final VideoplayerRoute route = buildVideoplayerRoute(
    operatingSystem: operatingSystem ?? currentTrailerPlayerOperatingSystem(),
    target: target,
    // The host already resolves the form factor; there is no second TV probe.
    isTv: isTv,
  );
  return switch (route) {
    TizenAvplayRoute(:final target) => TizenAvplayPlayer(
      target: target,
      watchProgressRecorder: watchProgressRecorder,
      onPlaybackEvent: onPlaybackEvent,
      options: options,
    ),
    NativeTvPlayerRoute(:final target) => SystemVideoPlayer(
      target: target,
      useSharedOverlay: true,
      watchProgressRecorder: watchProgressRecorder,
      onPlaybackEvent: onPlaybackEvent,
      options: options,
    ),
    // Casting is offered on phones and tablets only: the TV routes are
    // already on the big screen.
    NativePlayerRoute(:final target) => SystemVideoPlayer(
      target: target,
      watchProgressRecorder: watchProgressRecorder,
      onPlaybackEvent: onPlaybackEvent,
      castAvailable: castAvailable,
      onCastRequested: onCastRequested,
      options: options,
    ),
    NoPlayerRoute(:final operatingSystem) => NoPlayerSurface(
      operatingSystem: operatingSystem,
    ),
  };
}
