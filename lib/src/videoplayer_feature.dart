import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/source.dart';

import 'bloc/videoplayer_feature_bloc.dart';
import 'player/default_player_builder.dart';
import 'player/platform_detector.dart';
import 'player/playback_event.dart';
import 'player/player_loading_indicator.dart';
import 'player/watch_progress_recorder.dart';
import 'player/playback_target.dart';
import 'player/player_options.dart';
import 'player/player_policy.dart';
import 'l10n/streaming_l10n.dart';

typedef VideoplayerFeaturePlayerBuilder =
    Widget Function(BuildContext context, VideoplayerTarget target);

class VideoplayerFeatureView extends StatelessWidget {
  /// Source-based playback. Tizen plays it through AVPlay, Android and iOS
  /// through the native system player; every other platform shows no player.
  ///
  /// An [EyzflowTrailer] source (or one with no
  /// [EyzflowSource.sourceType] at all, for legacy callers)
  /// becomes a [VideoplayerTrailerTarget] — never DRM-protected. An
  /// [EyzflowFilm] source becomes a [VideoplayerSourceTarget],
  /// which carries the source's own DRM license request: Widevine on Tizen
  /// and Android, FairPlay on iOS.
  VideoplayerFeatureView({
    super.key,
    required EyzflowSource videoSource,
    this.onCloseRequested,
    this.playerBuilder,
    this.watchProgressRecorder,
    this.onPlaybackEvent,
    this.debugOperatingSystemOverride,
    this.isTv = false,
    this.castAvailable = false,
    this.onCastRequested,
    this.options = const PlayerOptions(),
  }) : target =
           videoSource.sourceType == null ||
               videoSource.sourceType is EyzflowTrailer
           ? VideoplayerTrailerTarget(videoSource)
           : VideoplayerSourceTarget(videoSource);

  /// The only entry point, and it requires a source.
  ///
  /// A Watch request that resolves no stream never reaches this view: Access
  /// Control turns it into an `AccessControlError`, which the Watch button
  /// shows as an alert that returns to Content Detail. There is deliberately
  /// no source-less player surface to fall back to.
  final VideoplayerTarget target;

  final VoidCallback? onCloseRequested;
  final VideoplayerFeaturePlayerBuilder? playerBuilder;

  /// Records what the viewer watched. Absent in previews and tests, and for a
  /// trailer, which is not something a viewer resumes.
  final WatchProgressRecorder? watchProgressRecorder;

  /// Hears what playback does — started, paused, seeked, stalled, failed,
  /// completed, closed; see [PlaybackEvent] — so the host can map it onto
  /// whatever analytics tool it uses. This package imports none. Absent,
  /// nothing is observed and the player behaves exactly as it did without it.
  ///
  /// Called synchronously from the player's listeners: keep it cheap. One
  /// that throws is logged and ignored rather than allowed to disturb
  /// playback. [PlaybackClosed] arrives just after the player is disposed, so
  /// a callback that touches a `State` must check `mounted` first.
  ///
  /// Each player reports its own sequence, so the Retry on the Android
  /// failure alert, which builds a fresh player, begins a new one after the
  /// failed player's [PlaybackClosed].
  ///
  /// What cannot be reported: an audio or subtitle switch made in the native
  /// controls on a phone or tablet, because the native player does not tell
  /// Dart about it. A seek made there is inferred from the position jumping,
  /// so one of less than a few seconds is missed. On TV both come from the
  /// controls overlay and are reported as they happen. Not passed to a custom
  /// [playerBuilder], which owns its own player.
  final PlaybackEventCallback? onPlaybackEvent;

  /// Test seam only: forces the operating system used to decide whether the
  /// shared Close button is shown. Production reads the real platform.
  final String? debugOperatingSystemOverride;

  /// Whether the host runs as a TV app. The package does not probe the form
  /// factor itself; the host already knows it. It selects the Android TV
  /// route (shared D-pad overlay instead of native touch controls), skips the
  /// phone landscape lock, and sizes the TV chrome.
  final bool isTv;

  /// Shows a Cast button on phones and tablets (inside the native controls on
  /// Android, over the player on iOS). The host sets it once it found a Cast
  /// device. Ignored on TV and by a custom [playerBuilder].
  final bool castAvailable;

  /// A tap on the Cast button, with the playback position.
  final void Function(Duration position)? onCastRequested;

  /// A player config's features and theme, mapped to the app players. Not
  /// passed to a custom [playerBuilder].
  final PlayerOptions options;

  @override
  Widget build(BuildContext context) {
    return _FullscreenScope(
      lockLandscape:
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          !isTv &&
          MediaQuery.sizeOf(context).shortestSide < 600,
      child: BlocProvider(
        create: (_) =>
            VideoplayerFeatureBloc(target: target)
              ..add(const VideoplayerFeatureStarted()),
        child: _VideoplayerFeatureContent(
          onCloseRequested: onCloseRequested,
          playerBuilder: playerBuilder,
          watchProgressRecorder: watchProgressRecorder,
          onPlaybackEvent: onPlaybackEvent,
          debugOperatingSystemOverride: debugOperatingSystemOverride,
          isTv: isTv,
          castAvailable: castAvailable,
          onCastRequested: onCastRequested,
          options: options,
        ),
      ),
    );
  }
}

class _FullscreenScope extends StatefulWidget {
  const _FullscreenScope({required this.child, required this.lockLandscape});

  final Widget child;
  final bool lockLandscape;

  @override
  State<_FullscreenScope> createState() => _FullscreenScopeState();
}

class _FullscreenScopeState extends State<_FullscreenScope> {
  late final bool _lockedLandscape;

  @override
  void initState() {
    super.initState();
    _lockedLandscape = widget.lockLandscape;
    if (_lockedLandscape) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
    unawaited(_setSystemUiMode(true));
  }

  @override
  void dispose() {
    if (_lockedLandscape) {
      // The app otherwise follows the device's orientation preference.
      unawaited(SystemChrome.setPreferredOrientations(const []));
    }
    unawaited(_setSystemUiMode(false));
    super.dispose();
  }

  Future<void> _setSystemUiMode(bool isFullscreen) async {
    if (kIsWeb) {
      return;
    }

    final platform = defaultTargetPlatform;
    if (platform == TargetPlatform.android) {
      await _setAndroidSystemUiMode(isFullscreen);
      return;
    }

    if (platform != TargetPlatform.iOS) {
      return;
    }

    await _setIosSystemUiMode(isFullscreen);
  }

  Future<void> _setAndroidSystemUiMode(bool isFullscreen) async {
    if (isFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: const [],
      );
      return;
    }

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _setIosSystemUiMode(bool isFullscreen) async {
    if (isFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const [],
      );
      return;
    }

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _VideoplayerFeatureContent extends StatelessWidget {
  const _VideoplayerFeatureContent({
    required this.playerBuilder,
    this.onCloseRequested,
    this.watchProgressRecorder,
    this.onPlaybackEvent,
    this.debugOperatingSystemOverride,
    required this.isTv,
    this.castAvailable = false,
    this.onCastRequested,
    this.options = const PlayerOptions(),
  });

  final VoidCallback? onCloseRequested;
  final VideoplayerFeaturePlayerBuilder? playerBuilder;
  final WatchProgressRecorder? watchProgressRecorder;
  final PlaybackEventCallback? onPlaybackEvent;
  final String? debugOperatingSystemOverride;
  final bool isTv;
  final bool castAvailable;
  final void Function(Duration position)? onCastRequested;
  final PlayerOptions options;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<VideoplayerFeatureBloc, VideoplayerFeatureState>(
      listenWhen: (previous, current) =>
          previous.featureState != current.featureState &&
          current.featureState == VideoplayerFeatureStatus.finished,
      listener: (context, state) {
        _closePlayer(context, onCloseRequested);
      },
      builder: (context, state) {
        if (state.featureState == VideoplayerFeatureStatus.loading) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: PlayerLoadingIndicator(isTv: isTv)),
          );
        }

        final String? os =
            debugOperatingSystemOverride ??
            currentTrailerPlayerOperatingSystem();
        if (state.featureState == VideoplayerFeatureStatus.failed) {
          return Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: _PlaybackAlert(
                isTv: isTv,
                title: Text(streamingL10n.playbackUnavailable),
                content: Text(
                  state.errorMessage ?? streamingL10n.unableToLoadVideo,
                ),
                actions: [
                  if (os == 'android')
                    TextButton(
                      onPressed: () => context
                          .read<VideoplayerFeatureBloc>()
                          .add(const VideoplayerFeatureRetryRequested()),
                      child: Text(streamingL10n.retryPlayback),
                    ),
                  TextButton(
                    autofocus: true,
                    onPressed: () => _closePlayer(context, onCloseRequested),
                    child: Text(streamingL10n.ok),
                  ),
                ],
              ),
            ),
          );
        }

        // Android native controls and TV overlays own their Close control.
        // A Flutter button above Media3 would outlive its auto-hide animation.
        final VideoplayerRoute route = buildVideoplayerRoute(
          operatingSystem: os,
          target: state.target,
          isTv: isTv,
        );
        final bool overlayOwnsClose =
            route is TizenAvplayRoute ||
            route is NativeTvPlayerRoute ||
            (os == 'android' && route is NativePlayerRoute);

        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child:
                    playerBuilder?.call(context, state.target) ??
                    buildDefaultVideoplayerPlayer(
                      context,
                      state.target,
                      operatingSystem: debugOperatingSystemOverride,
                      isTv: isTv,
                      watchProgressRecorder: watchProgressRecorder,
                      onPlaybackEvent: onPlaybackEvent,
                      castAvailable: castAvailable,
                      onCastRequested: onCastRequested,
                      options: options,
                    ),
              ),
              if (!overlayOwnsClose && !state.isPictureInPicture)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 8,
                  left: 8,
                  child: IconButton(
                    onPressed: () => _closePlayer(context, onCloseRequested),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: streamingL10n.closePlayer,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

void _closePlayer(BuildContext context, VoidCallback? handler) {
  if (handler != null) {
    handler();
  } else {
    Navigator.of(context).pop();
  }
}

/// The playback-failure alert: a black compact surface, owned here so the
/// package depends on no app design system.
/// It sits on the player's black scaffold, so TV needs no frosted backdrop.
class _PlaybackAlert extends StatelessWidget {
  const _PlaybackAlert({
    required this.isTv,
    required this.title,
    required this.content,
    required this.actions,
  });

  final bool isTv;
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Size viewport = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: title,
      content: content,
      actions: actions,
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 0),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 20),
      constraints: BoxConstraints(
        maxWidth: viewport.width >= 600 ? viewport.width * 0.6 : 360,
        maxHeight: isTv && viewport.height >= 600
            ? viewport.height * 0.45
            : math.min(viewport.height - 48, 480),
      ),
      titleTextStyle: text.titleLarge?.copyWith(color: Colors.white),
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
    );
  }
}
