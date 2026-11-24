import 'dart:async';

import '../ads/ad_breaks.dart';
import '../ads/ad_countdown.dart';
import '../ads/ad_scheduler.dart';
import '../ads/ima_ad_driver.dart';
import '../native/native_video_player.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import '../core/source.dart';
import '../cast/cast_track_scope.dart';

import '../bloc/player_controls_bloc.dart';
import '../bloc/videoplayer_feature_bloc.dart';
import '../end_screen/end_screen.dart' show PlayerOverlayControls;
import '../end_screen/end_screen_view.dart';
import '../signals/stream_signals.dart';
import 'ad_countdown_notice.dart';
import 'hls_renditions.dart';
import 'playback_event.dart';
import 'playback_event_emitter.dart';
import 'playback_target.dart';
import 'player_controls.dart';
import 'player_log.dart';
import 'player_options.dart';
import 'player_policy.dart';
import 'skip_signal_button.dart';
import 'system_drm_config.dart';
import 'subtitle_preference_store.dart';
import 'system_player_tracks.dart';
import 'watch_progress_recorder.dart';
import '../l10n/streaming_l10n.dart';
import 'player_loading_indicator.dart';

var _nextSystemPlayerId = 0;

typedef _ListenerBinding = ({
  StreamSubscription<Duration> position,
  void Function(PlayerActivityEvent) activity,
});

/// Android and iOS play through this widget: a DRM-capable native player
/// with its own system controls. There is no custom overlay here — unlike
/// Tizen, the plugin's native UI already covers play/pause/scrub/track
/// selection, so nothing is extracted from or adapted out of
/// `PlayerControls`, which is deliberately remote/focus-shaped.
class SystemVideoPlayer extends StatefulWidget {
  const SystemVideoPlayer({
    super.key,
    required this.target,
    this.createController,
    this.watchProgressRecorder,
    this.onPlaybackEvent,
    this.useSharedOverlay = false,
    this.castAvailable = false,
    this.onCastRequested,
    this.options = const PlayerOptions(),
    this.createAdDriver,
    this.loadAdBreaks,
    this.loadSignals,
  });

  final VideoplayerTarget target;
  final VideoplaybackControllerFactory? createController;

  /// Replaces Google IMA. A test seam.
  final AdDriver Function(SystemPlayerAdHooks hooks)? createAdDriver;

  /// Replaces reading the ad break markers from the manifest. A test seam.
  final Future<List<AdBreak>> Function(Uri master)? loadAdBreaks;

  /// Replaces reading the intro, recap and credits signals from the manifest.
  /// A test seam.
  final Future<List<StreamSignal>> Function(Uri master)? loadSignals;

  /// Records what the viewer watched. Absent in previews and tests, and for
  /// a trailer, which is not something a viewer resumes.
  final WatchProgressRecorder? watchProgressRecorder;

  /// Hears what playback does, for the host's analytics. Absent, nothing is
  /// observed and the player behaves exactly as it did without it.
  ///
  /// With the native controls (phones and tablets) a seek is inferred from
  /// the position jumping, and an audio or subtitle switch is not reported at
  /// all: the plugin's native UI makes both without telling Dart. With the
  /// shared overlay (Android TV) both come from the overlay itself.
  final PlaybackEventCallback? onPlaybackEvent;

  /// Renders the shared [PlayerControls] overlay instead of the plugin's
  /// native UI. True on Android TV, where the native controls are touch-shaped
  /// and unreachable by D-pad; false on phones and tablets, where the native
  /// UI is the better one.
  final bool useSharedOverlay;

  /// Shows a Cast button with the native controls: inside Media3's controls
  /// on Android (it fades with them), top right over the player on iOS. The
  /// host sets it once it found a Cast device. Never with [useSharedOverlay].
  final bool castAvailable;

  /// A tap on the Cast button, with the playback position. Playback goes on;
  /// the host decides what casting means.
  final void Function(Duration position)? onCastRequested;

  /// A player config's features (and, with [useSharedOverlay], its theme).
  /// Read when the native player is created.
  final PlayerOptions options;

  bool get _showsCast => castAvailable && !useSharedOverlay;

  @override
  State<SystemVideoPlayer> createState() => _SystemVideoPlayerState();
}

class _SystemVideoPlayerState extends State<SystemVideoPlayer> {
  VideoplaybackSession? _session;
  WatchProgressRecorder? _sessionRecorder;

  /// One per session, so a replaced target closes its own sequence and the
  /// next one starts clean.
  PlaybackEventEmitter? _events;
  NativeVideoPlayerController? _nativeController;
  var _request = 0;
  StreamSubscription<AndroidPlaybackEvent>? _androidEvents;
  StreamSubscription<bool>? _pipEvents;
  StreamSubscription<Duration>? _castRequests;

  /// Ads for the current session, when the config has an ad tag.
  AdBreakScheduler? _ads;
  ImaAdDriver? _imaDriver;
  var _finishing = false;

  /// Seconds (the countdown's length … 1) until the next mid-roll while its
  /// notice shows.
  final ValueNotifier<int?> _adCountdown = ValueNotifier<int?>(null);
  VideoplaybackValue? _lastValue;
  Duration? _countdownPosition;

  /// The intro, recap or credits signal playback is in.
  final SignalTracker _signals = SignalTracker();

  /// Where playback is, for the overlay layer (end screen, app overlay).
  final ValueNotifier<PlaybackFacts> _facts = ValueNotifier<PlaybackFacts>(
    const PlaybackFacts(),
  );

  /// Whether the overlay layer shows something: the skip button stays away.
  final PlayerOverlayState _overlay = PlayerOverlayState();

  @override
  void initState() {
    super.initState();
    _overlay.addListener(_onOverlayChanged);
    unawaited(_start());
  }

  void _onOverlayChanged() {
    if (!mounted) return;
    setState(() {});
    // AVKit's (and Android's) native full screen covers everything Flutter
    // draws: the end screen or the app's overlay would show behind it. Leave
    // it, so the viewer sees them.
    final NativeVideoPlayerController? native = _nativeController;
    if (_overlay.active && native != null && native.isFullScreen) {
      unawaited(native.exitFullScreen());
    }
  }

  void _checkpoint([Duration? position]) {
    final recorder = _sessionRecorder;
    final latest =
        position ??
        _nativeController?.currentPosition ??
        _playback?.value.position;
    if (latest != null && (_session?.canRecordPosition(latest) ?? false)) {
      recorder?.checkpoint(latest);
    }
    if (recorder != null) unawaited(recorder.flush());
  }

  VoidCallback? _detachCastTracks;

  void _retireNative() {
    _detachCastTracks?.call();
    _detachCastTracks = null;
    _checkpoint();
    unawaited(_androidEvents?.cancel());
    unawaited(_pipEvents?.cancel());
    unawaited(_castRequests?.cancel());
    _androidEvents = null;
    _pipEvents = null;
    _castRequests = null;
    final native = _nativeController;
    _nativeController = null;
    if (native != null) {
      unawaited(native.setAndroidPlayerRouteActive(false));
      // Unblock a pending platform mount before awaiting session disposal.
      final playback = _playback;
      if (playback is _SystemPlayerController) unawaited(playback.dispose());
      unawaited(native.dispose());
    }
  }

  /// The controller the session created, captured generically so the overlay
  /// works on both the real Android path and the test-injected path.
  VideoplaybackController? _playback;
  VideoplaybackTracks? _playbackTracks;
  PlayerControlsBloc? _controlsBloc;
  var _tickBridged = false;
  var _tracksRequested = false;

  @override
  void didUpdateWidget(SystemVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _events?.onEvent = widget.onPlaybackEvent;
    if (oldWidget._showsCast != widget._showsCast) _syncCastButton();
    // useSharedOverlay is captured in the controller's `showNativeControls`
    // when it is built, so a flip needs a new controller: reusing the old one
    // would leave the plugin's native controls live underneath the shared
    // overlay, or strip them with nothing in their place.
    if (oldWidget.target != widget.target ||
        oldWidget.useSharedOverlay != widget.useSharedOverlay) {
      unawaited(_replace(++_request));
    }
  }

  /// Ends the current session's event sequence.
  ///
  /// A microtask later, not now: this runs from `dispose` and
  /// `didUpdateWidget`, where the widget tree is locked, and a host callback
  /// that rebuilds anything — the example's on-screen log does — would
  /// assert. The session being retired may still tick in between; those
  /// ticks belong to the same sequence and still precede the close.
  void _closeEvents() {
    final PlaybackEventEmitter? events = _events;
    _events = null;
    if (events != null) scheduleMicrotask(events.close);
  }

  Future<void> _replace(int request) async {
    _closeEvents();
    _disposeAds();
    _retireNative();
    final VideoplaybackSession? retiredSession = _session;
    await retiredSession?.dispose();
    if (!mounted ||
        request != _request ||
        !identical(_session, retiredSession)) {
      return;
    }
    _session = null;
    _nativeController = null;
    unawaited(_controlsBloc?.close() ?? Future<void>.value());
    _controlsBloc = null;
    _playback = null;
    _playbackTracks = null;
    _tickBridged = false;
    _tracksRequested = false;
    await _start();
  }

  Future<void> _start() async {
    final WatchProgressRecorder? recorder = widget.watchProgressRecorder;
    _sessionRecorder = recorder;
    _finishing = false;
    final PlaybackEventEmitter events = PlaybackEventEmitter(
      sourceId: switch (widget.target) {
        VideoplayerTrailerTarget(:final source) => source.id,
        VideoplayerSourceTarget(:final source) => source.id,
      },
      onEvent: widget.onPlaybackEvent,
    );
    _events = events;
    final Future<HlsMarkers> markers = _loadMarkers(
      _masterPlaylist(widget.target),
    );
    _signals
      ..onStarted = events.signalStarted
      ..onEnded = events.signalEnded
      ..position(null)
      ..signals = const <StreamSignal>[];
    _facts.value = const PlaybackFacts();
    unawaited(
      markers.then((HlsMarkers found) {
        if (mounted && identical(_events, events)) {
          _signals.signals = found.signals;
        }
      }),
    );
    final AdBreakScheduler? ads = _setUpAds(events, markers);
    final VideoplaybackSession session = VideoplaybackSession(
      target: widget.target,
      createController: _createAndCaptureController,
      onFinished: _finished,
      onFailure: _fail,
      onProgress: recorder == null
          ? null
          : (Duration position, Duration duration) =>
                recorder.report(position, duration: duration),
      onInitialized: (VideoplaybackValue value) =>
          events.ready(position: value.position, duration: value.duration),
      onValue: (VideoplaybackValue value) {
        events.tick(value);
        final Duration? position = value.position;
        if (ads != null && position != null && !value.isCompleted) {
          ads.contentPosition(position);
        }
        _updateAdCountdown(value);
        _signals.position(value.isCompleted ? null : position);
        _facts.value = PlaybackFacts(
          position: position,
          duration: value.duration,
          playing: value.isPlaying,
          ended: value.isCompleted,
        );
      },
      // Android: the pre-roll plays before the content player loads (below).
      beforePlay: _prerollBeforeLoad ? null : ads?.beforeContent,
    );
    _session = session;
    if (ads != null && _prerollBeforeLoad) {
      // TVs (and some phones) have one hardware video decoder: while the
      // content player holds it, IMA's ad player gets none and shows a black
      // picture under its countdown. So the pre-roll plays first.
      await ads.beforeContent();
      if (!mounted || !identical(_session, session)) return;
    }
    await session.start();
    if (!mounted || !identical(_session, session)) return;
    final tracks = _playbackTracks;
    if (!widget.useSharedOverlay && tracks != null) {
      _detachCastTracks = context
          .getInheritedWidgetOfExactType<CastTrackScope>()
          ?.attach(tracks);
    }
    // Overlay mode needs a rebuild once the controller exists: unlike the
    // native-controls path, nothing else calls setState on the injected-
    // controller path, so the overlay would never be built.
    if (widget.useSharedOverlay && mounted && identical(_session, session)) {
      setState(() {});
    }
  }

  bool get _prerollBeforeLoad =>
      defaultTargetPlatform == TargetPlatform.android;

  /// The ads scheduler for a new session, or null without an ad tag. The
  /// markers are read from the manifest while the player starts.
  AdBreakScheduler? _setUpAds(
    PlaybackEventEmitter events,
    Future<HlsMarkers> markers,
  ) {
    _disposeAds();
    final PlayerAds? ads = widget.options.ads;
    if (ads == null) return null;
    final SystemPlayerAdHooks hooks = SystemPlayerAdHooks(
      adTagUrl: ads.adTagUrl,
      pauseContent: () => unawaited(_pauseForAd()),
      resumeContent: () => unawaited(_resumeAfterAd()),
      contentDuration: () => _playback?.value.duration,
      scheduler: () => _ads!,
    );
    final AdDriver driver;
    final AdDriver Function(SystemPlayerAdHooks)? create =
        widget.createAdDriver;
    if (create != null) {
      driver = create(hooks);
    } else {
      final ImaAdDriver ima = _imaDriver = ImaAdDriver(
        adTagUrl: hooks.adTagUrl,
        onPauseContent: hooks.pauseContent,
        onResumeContent: hooks.resumeContent,
        contentDuration: hooks.contentDuration,
      );
      driver = ima;
    }
    final AdBreakScheduler scheduler = AdBreakScheduler(
      ads: ads,
      driver: driver,
      onBreakStarted: events.adBreakStarted,
      onBreakEnded: events.adBreakEnded,
      // On AirPlay the video plays on the TV: no ads start then.
      suppressed: () => _nativeController?.isAirplayConnected ?? false,
    )..addListener(_onAdsChanged);
    _imaDriver?.scheduler = scheduler;
    _ads = scheduler;
    final Uri master = _masterPlaylist(widget.target);
    unawaited(
      ads.loadMarkers(() async {
        final Future<List<AdBreak>> Function(Uri)? load = widget.loadAdBreaks;
        if (load != null) return load(master);
        return (await markers).adBreaks;
      }),
    );
    return scheduler;
  }

  /// The stream's ad break markers and signals, read once per session from
  /// the playlist the native player loads.
  Future<HlsMarkers> _loadMarkers(Uri master) async {
    final Future<List<StreamSignal>> Function(Uri)? loadSignals =
        widget.loadSignals;
    if (loadSignals != null) {
      return (adBreaks: const <AdBreak>[], signals: await loadSignals(master));
    }
    final http.Client client = http.Client();
    try {
      return await loadHlsMarkers(client, master);
    } finally {
      client.close();
    }
  }

  /// Jumps to the end of the signal playback is in (the end of the content
  /// at most, which ends it).
  void _skipSignal() {
    final StreamSignal? signal = _signals.value;
    final VideoplaybackController? playback = _playback;
    if (signal == null || playback == null || (_ads?.inBreak ?? false)) {
      return;
    }
    final Duration? duration = playback.value.duration;
    final Duration target = duration != null && signal.end > duration
        ? duration
        : signal.end;
    _events?.seeked(playback.value.position ?? signal.start, target);
    _signals.skipped(signal, target);
    unawaited(playback.seekTo(target));
  }

  /// The content stops for a mid-roll. On Android its player also lets go
  /// of the video decoder: on a TV with one, IMA's ad would have no picture.
  Future<void> _pauseForAd() async {
    final VideoplaybackController? playback = _playback;
    if (playback is _SystemPlayerController && _prerollBeforeLoad) {
      await playback.controller.releaseForAd();
    } else {
      await playback?.pause();
    }
  }

  Future<void> _resumeAfterAd() async {
    final VideoplaybackController? playback = _playback;
    if (playback is _SystemPlayerController && _prerollBeforeLoad) {
      await playback.controller.restoreAfterAd();
    }
    await playback?.play();
  }

  void _onAdsChanged() {
    if (mounted) setState(() {});
    _syncCastButton();
    _updateAdCountdown(_lastValue, jumped: false);
  }

  /// The native Cast button: once a Cast device is found. On iOS it is
  /// hidden during an ad break, as AVKit's controls under it are.
  bool get _castButtonShown =>
      widget._showsCast &&
      !(defaultTargetPlatform == TargetPlatform.iOS &&
          (_ads?.inBreak ?? false));

  void _syncCastButton() {
    unawaited(_nativeController?.setCastButtonVisible(_castButtonShown));
  }

  /// The notice before a mid-roll, from the latest position report. Hidden
  /// while paused or buffering, when the position jumped (a seek: the native
  /// controls do not report one otherwise), while scrubbing on TV, during an
  /// ad break and on AirPlay. A break seeked past is behind the position, so
  /// it has no notice.
  void _updateAdCountdown(VideoplaybackValue? value, {bool? jumped}) {
    final AdBreakScheduler? ads = _ads;
    _lastValue = value;
    final Duration? position = value?.position;
    final Duration? previous = _countdownPosition;
    if (jumped == null) _countdownPosition = position;
    final bool seeked =
        jumped ??
        (position != null &&
            previous != null &&
            (position < previous || position - previous > maxPlayStep));
    final PlayerControlsBloc? bloc = _controlsBloc;
    final bool scrubbing =
        bloc != null &&
        !bloc.isClosed &&
        (bloc.state.isScrubbing || bloc.state.isPreviewing);
    _adCountdown.value = ads == null || value == null
        ? null
        : adCountdownFor(
            enabled: widget.options.adCountdown,
            playing:
                value.isPlaying &&
                !value.isBuffering &&
                !value.isCompleted &&
                !seeked &&
                !scrubbing,
            inBreak: ads.inBreak || ads.adPlaying,
            remote: _nativeController?.isAirplayConnected ?? false,
            position: position,
            starts: ads.upcomingMidrolls,
            length: widget.options.adCountdownSeconds,
          );
  }

  void _disposeAds() {
    final AdBreakScheduler? ads = _ads;
    _adCountdown.value = null;
    _lastValue = null;
    _countdownPosition = null;
    _ads = null;
    _imaDriver = null;
    ads?.removeListener(_onAdsChanged);
    ads?.dispose();
  }

  Future<VideoplaybackController> _createAndCaptureController(
    VideoplayerTarget target,
  ) async {
    final VideoplaybackController controller =
        await (widget.createController ?? _createSystemController)(target);
    _playback = controller;
    // The cast is not redundant: the ternary's static type is the LUB of the
    // promoted type and Null, which drops back to VideoplaybackController?.
    _playbackTracks = controller is VideoplaybackTracks
        ? controller as VideoplaybackTracks
        : null;
    return controller;
  }

  Future<VideoplaybackController> _createSystemController(
    VideoplayerTarget target,
  ) async {
    final EYZFlowSource source = switch (target) {
      VideoplayerTrailerTarget(:final source) => source,
      VideoplayerSourceTarget(:final source) => source,
    };
    final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final PlayerOptions options = widget.options;
    final Map<String, dynamic>? drmConfig = systemDrmConfigForTarget(
      target,
      isIOS: isIOS,
    );
    if (kDebugMode) {
      logPlayback(
        'source.prepare url=${source.hlsStreamUrl} (hls, '
        'drm ${drmConfig?['type'] ?? 'none'})',
      );
    }
    final NativeVideoPlayerController nativeController =
        NativeVideoPlayerController(
          id: _nextSystemPlayerId++,
          showNativeControls: !widget.useSharedOverlay,
          androidFullscreenRoute: !isIOS && !widget.useSharedOverlay,
          androidCloseLabel: streamingL10n.closePlayer,
          androidCastLabel: streamingL10n.castTo,
          allowsPictureInPicture:
              !isIOS && !widget.useSharedOverlay && options.pictureInPicture,
          canStartPictureInPictureAutomatically:
              !isIOS && !widget.useSharedOverlay && options.pictureInPicture,
          enableLooping: options.loop,
          allowsExternalPlayback: options.airPlay,
          mediaInfo: NativeVideoPlayerMediaInfo(
            title: source.title,
            artworkUrl: source.poster?.toString(),
          ),
        );
    // Load-bearing: NativeVideoPlayerController.initialize() (below, in
    // _SystemPlayerController.initialize) blocks on a platform-view-creation
    // callback that only fires once NativeVideoPlayer is mounted. This
    // setState mounts it before VideoplaybackSession goes on to await
    // initialize() -- do not move this into _start()/gate it behind a
    // "ready" flag, that reintroduces the deadlock fixed in a9c4adeb (no
    // test catches it: the fake controllers used in tests have no
    // platform-view dependency).
    if (mounted) {
      setState(() => _nativeController = nativeController);
    } else {
      _nativeController = nativeController;
    }
    _androidEvents = nativeController.androidPlaybackEvents.listen((event) {
      if (!mounted || !identical(_nativeController, nativeController)) return;
      _checkpoint(event.position);
      if (event.closed) {
        context.read<VideoplayerFeatureBloc>().add(
          const VideoplayerFeaturePlaybackFinished(),
        );
      }
    });
    _castRequests = nativeController.castRequests.listen((position) {
      if (!mounted || !identical(_nativeController, nativeController)) return;
      widget.onCastRequested?.call(position);
    });
    if (widget._showsCast) {
      unawaited(nativeController.setCastButtonVisible(_castButtonShown));
    }
    _pipEvents = nativeController.isPipEnabledStream.listen((enabled) {
      if (!mounted || !identical(_nativeController, nativeController)) return;
      context.read<VideoplayerFeatureBloc>().add(
        VideoplayerFeaturePictureInPictureChanged(enabled),
      );
    });
    return _SystemPlayerController(
      nativeController,
      url: source.hlsStreamUrl.toString(),
      drmConfig: drmConfig,
    );
  }

  void _finished() {
    // Recorded before the bloc tears the session down, so the completion is
    // written even though the view is about to go away.
    _sessionRecorder?.finish();
    final AdBreakScheduler? ads = _ads;
    if (ads == null) {
      _closeUnlessEndScreen();
      return;
    }
    // A VMAP's post-roll plays before the player closes.
    if (_finishing) return;
    _finishing = true;
    unawaited(ads.contentCompleted().whenComplete(_closeUnlessEndScreen));
  }

  /// At the end of the film: the player stays on the end screen when there is
  /// one; it closes from there (Close, Back, or a picked film).
  void _closeUnlessEndScreen() {
    if (mounted && endScreenAtTheEnd(context)) return;
    _close();
  }

  void _close() {
    if (mounted) {
      context.read<VideoplayerFeatureBloc>().add(
        const VideoplayerFeaturePlaybackFinished(),
      );
    }
  }

  void _fail(String message) {
    // A startup timeout or a load that threw never reaches a tick, so the
    // failure is reported from here; one a tick already reported is not
    // repeated.
    _events?.error(message);
    unawaited(_nativeController?.setAndroidPlayerRouteActive(false));
    _checkpoint();
    if (mounted) {
      context.read<VideoplayerFeatureBloc>().add(
        VideoplayerFeatureSourceFailed(message),
      );
    }
  }

  @override
  void dispose() {
    _request++;
    _signals.dispose();
    _overlay.removeListener(_onOverlayChanged);
    _overlay.dispose();
    _facts.dispose();
    _disposeAds();
    _closeEvents();
    _retireNative();
    unawaited(_session?.dispose() ?? Future<void>.value());
    unawaited(_controlsBloc?.close() ?? Future<void>.value());
    // Independently of the session's disposal chain above: if we're torn
    // down before the native side's first activity event arrives,
    // VideoplaybackSession awaits a startup future that never resolves, so
    // its own call to controller.dispose() (and therefore
    // nativeController.dispose()) is never reached. Disposing the raw
    // controller here guarantees the native player, its event-channel
    // subscription, and its WidgetsBinding observer are cleaned up either
    // way. NativeVideoPlayerController.dispose() is _isDisposed-guarded and
    // idempotent, so this is safe even when the session's own path succeeds.
    unawaited(_nativeController?.dispose());
    _adCountdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final NativeVideoPlayerController? controller = _nativeController;
    // Keyed by controller id: NativeVideoPlayer caches its platform view for
    // the life of its State and ignores a controller change in its own
    // didUpdateWidget, so without this key a target-change swap (see
    // _replace) would reuse the old platform view and the new controller's
    // initialize() would hang waiting for onPlatformViewCreated.
    final Widget surface = controller == null
        // In overlay mode a test-injected controller has no platform view, so
        // a black fill stands in — the same shape as the Tizen path.
        ? (widget.useSharedOverlay
              ? const ColoredBox(color: Colors.black)
              : const Center(child: PlayerLoadingIndicator()))
        : SizedBox.expand(
            child: NativeVideoPlayer(
              key: ValueKey<int>(controller.id),
              controller: controller,
            ),
          );

    final bool inAdBreak = _ads?.inBreak ?? false;
    // The surface with the end screen or the app's overlay over it; it can
    // shrink the surface into a corner. Always present, so the platform view
    // keeps its place in the tree.
    final Widget layered = PlayerOverlayLayer(
      surface: surface,
      signal: _signals,
      facts: _facts,
      inAdBreak: inAdBreak,
      state: _overlay,
      theme: widget.options.controlsTheme,
      remote: widget.useSharedOverlay,
      controls: PlayerOverlayControls(
        skip: _skipSignal,
        seek: (Duration position) =>
            unawaited(_playback?.seekTo(position) ?? Future<void>.value()),
        play: () => unawaited(_playback?.play() ?? Future<void>.value()),
        pause: () => unawaited(_playback?.pause() ?? Future<void>.value()),
        dismiss: () {},
      ),
    );
    // Over the controls: during an ad break it takes the input.
    final Widget? adLayer = switch ((_ads, _imaDriver)) {
      (final AdBreakScheduler ads, final ImaAdDriver driver) => AdLayer(
        scheduler: ads,
        driver: driver,
      ),
      _ => null,
    };
    // Over the video and the controls, never focusable: on TV it stays up
    // while the controls are hidden. Switched off without a reload.
    final bool skipButtons = widget.options.skipButtons && !_overlay.active;
    final Widget? countdown = _ads != null && widget.options.adCountdown
        ? AdCountdownNotice(
            seconds: _adCountdown,
            liftedBy: skipButtons ? _signals : null,
          )
        : null;

    if (!widget.useSharedOverlay) {
      // The Cast button is native (over AVKit's controls on iOS, on the
      // fullscreen route on Android). One Stack from the first frame, surface
      // at index 0, so the ads appearing never re-parent the platform view.
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          layered,
          if (skipButtons && !inAdBreak)
            SkipSignalButton(
              signal: _signals,
              onSkip: _skipSignal,
              theme: widget.options.controlsTheme,
              types: widget.options.skipButtonTypes,
            ),
          ?adLayer,
          ?countdown,
        ],
      );
    }

    // One Stack from the first frame, surface always at index 0: moving the
    // NativeVideoPlayer under a new parent once the controls became ready
    // disposed its platform view and created another, while the plugin
    // controller kept addressing the first view id — every view-routed call
    // after that (subtitle tracks, track selection, dispose) failed NO_VIEW.
    final Widget? controls = _buildControls(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        layered,
        if (controls != null)
          // Hidden and out of the remote's reach during an ad break: no
          // focus, so no seek, no track panel. Kept alive for after it.
          Visibility(
            visible: !inAdBreak,
            maintainState: true,
            child: ExcludeFocus(excluding: inAdBreak, child: controls),
          ),
        ?countdown,
        ?adLayer,
      ],
    );
  }

  Widget? _buildControls(BuildContext context) {
    final VideoplaybackController? playback = _playback;
    final VideoplaybackTracks? tracks = _playbackTracks;
    if (playback == null || tracks == null) return null;

    final PlayerControlsBloc bloc = _ensureControlsBloc(playback, tracks);
    _bridgeTick(playback, bloc);
    unawaited(_loadTracksOnce(tracks, bloc));

    final EYZFlowSource source = switch (widget.target) {
      VideoplayerTrailerTarget(:final source) => source,
      VideoplayerSourceTarget(:final source) => source,
    };
    final String title = source.title;

    return BlocProvider<PlayerControlsBloc>.value(
      value: bloc,
      child: PlayerControls(
        title: title,
        thumbnailsUrl: source.thumbnailsUrl,
        // The same exit Tizen takes: the feature Bloc owns closing the
        // player, so both TV paths leave through one door.
        onBack: () => _closeFromControls(context),
        theme: widget.options.controlsTheme,
        showControls: widget.options.controls,
        signal: _signals,
        onSkipSignal: _skipSignal,
        skipButton: widget.options.skipButtons && !_overlay.active,
        skipButtonTypes: widget.options.skipButtonTypes,
      ),
    );
  }

  void _closeFromControls(BuildContext context) {
    context.read<VideoplayerFeatureBloc>().add(
      const VideoplayerFeaturePlaybackFinished(),
    );
  }

  PlayerControlsBloc _ensureControlsBloc(
    VideoplaybackController playback,
    VideoplaybackTracks tracks,
  ) => _controlsBloc ??= PlayerControlsBloc(
    controller: playback,
    tracks: tracks,
    subtitlePreferenceStore: getSubtitlePreferenceStoreOrNull(),
    hidesWhenIdle: widget.options.autoHideControls,
    captions: widget.options.captions,
    onSeeked: _events?.seeked,
    onAudioTrackChanged: _events?.audioTrackChanged,
    onSubtitleTrackChanged: _events?.subtitleTrackChanged,
  );

  /// Bridges the controller's ticks into the Bloc through the package's own
  /// contract — no plugin type reaches this widget, so a test fake drives it
  /// exactly as the real adapter does. Separate from the
  /// [VideoplaybackSession] listener that records watch progress, so neither
  /// disturbs the other.
  void _bridgeTick(VideoplaybackController playback, PlayerControlsBloc bloc) {
    if (_tickBridged) return;
    _tickBridged = true;
    playback.addListener((VideoplaybackValue value) {
      if (bloc.isClosed) return;
      final Duration? position = value.position;
      final Duration? duration = value.duration;
      if (position == null || duration == null) return;
      bloc.add(
        PlayerControlsValueTicked(
          position: position,
          duration: duration,
          isPlaying: value.isPlaying,
        ),
      );
      bloc.add(PlayerControlsBufferingChanged(value.isBuffering));
    });
  }

  Future<void> _loadTracksOnce(
    VideoplaybackTracks tracks,
    PlayerControlsBloc bloc,
  ) async {
    if (_tracksRequested) return;
    _tracksRequested = true;
    final annotated = await annotateHlsTracks(
      _masterPlaylist(widget.target),
      await tracks.audioTracks(),
      await tracks.textTracks(),
    );
    if (!mounted || bloc.isClosed) return;
    bloc.add(
      PlayerControlsTracksLoaded(
        audioTracks: annotated.audio,
        textTracks: annotated.text,
      ),
    );
  }
}

/// What [SystemVideoPlayer] gives an ads driver: the tag, and the content
/// player to pause and resume around an ad break.
final class SystemPlayerAdHooks {
  const SystemPlayerAdHooks({
    required this.adTagUrl,
    required this.pauseContent,
    required this.resumeContent,
    required this.contentDuration,
    required this.scheduler,
  });

  final String adTagUrl;
  final VoidCallback pauseContent;
  final VoidCallback resumeContent;
  final Duration? Function() contentDuration;

  /// The scheduler the driver reports the SDK's answers to.
  final AdBreakScheduler Function() scheduler;
}

Uri _masterPlaylist(VideoplayerTarget target) => switch (target) {
  VideoplayerTrailerTarget(:final source) => source.hlsStreamUrl,
  VideoplayerSourceTarget(:final source) => source.hlsStreamUrl,
};

/// Adapts [NativeVideoPlayerController] to the package's plugin-agnostic
/// playback contract, including track discovery and selection so the shared
/// controls overlay can drive it on Android TV. On phones and tablets the
/// plugin's own native UI is shown instead and these members go unused — they
/// cost nothing when idle.
final class _SystemPlayerController
    implements VideoplaybackController, VideoplaybackTracks {
  _SystemPlayerController(
    this.controller, {
    required this.url,
    required this.drmConfig,
  }) {
    if (_isAndroid) {
      _startupObserver = _AndroidStartupIntent();
    }
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  _AndroidStartupIntent? _startupObserver;
  int? _startupRevision;
  bool _startupCancelled = false;
  bool _firstPlay = true;
  bool _disposed = false;
  final _disposal = Completer<void>();

  final NativeVideoPlayerController controller;
  final String url;
  final Map<String, dynamic>? drmConfig;

  /// Last activity-event error, if any. The plugin exposes no synchronous
  /// "last error" getter, unlike `video_player_avplay`'s
  /// `VideoPlayerValue.errorDescription`, so this caches it from the
  /// activity listener instead.
  String? _lastErrorMessage;

  final Map<void Function(VideoplaybackValue), _ListenerBinding> _listeners =
      <void Function(VideoplaybackValue), _ListenerBinding>{};

  @override
  VideoplaybackValue get value => VideoplaybackValue(
    isCompleted: controller.activityState == PlayerActivityState.completed,
    errorMessage: _lastErrorMessage,
    position: controller.currentPosition,
    duration: controller.duration > Duration.zero ? controller.duration : null,
    isPlaying: controller.activityState == PlayerActivityState.playing,
    isBuffering: controller.activityState == PlayerActivityState.buffering,
    isPaused: controller.activityState == PlayerActivityState.paused,
  );

  @override
  Future<void> initialize() async {
    await Future.any([controller.initialize(), _disposal.future]);
    if (_disposed) return;
    if (_isAndroid) {
      _startupRevision = await controller.getAndroidPlaybackIntentRevision();
      _startupCancelled = _startupObserver?.cancelled ?? false;
      _startupObserver?.dispose();
      _startupObserver = null;
      if (_disposed) return;
      await controller.setAndroidPlayerRouteActive(true);
    }
    if (_disposed) return;
    await Future.any([
      controller.load(url: url, drmConfig: drmConfig),
      _disposal.future,
    ]);
  }

  /// Refreshed on enumeration. Cached because selection addresses the plugin's
  /// own track object, and re-fetching the whole list on every selection is a
  /// needless native round trip. Safe here, unlike on the AVPlay adapter:
  /// these are read only after initialize() and load() have completed.
  List<NativeVideoPlayerAudioTrack>? _nativeAudioTracks;
  List<NativeVideoPlayerSubtitleTrack>? _nativeTextTracks;

  @override
  int? selectedAudioTrackId;

  @override
  int? selectedTextTrackId;

  @override
  Future<List<PlayerAudioTrack>> audioTracks() async {
    final List<NativeVideoPlayerAudioTrack> tracks = _nativeAudioTracks =
        await controller.getAvailableAudioTracks();
    selectedAudioTrackId = systemSelectedIndex(
      tracks,
      (NativeVideoPlayerAudioTrack t) => t.isSelected,
      (NativeVideoPlayerAudioTrack t) => t.index,
    );
    return systemAudioTracks(tracks);
  }

  @override
  Future<List<PlayerTextTrack>> textTracks() async {
    final List<NativeVideoPlayerSubtitleTrack> tracks = _nativeTextTracks =
        await controller.getAvailableSubtitleTracks();
    selectedTextTrackId = systemSelectedIndex(
      tracks,
      (NativeVideoPlayerSubtitleTrack t) => t.isSelected,
      (NativeVideoPlayerSubtitleTrack t) => t.index,
    );
    return systemTextTracks(tracks);
  }

  @override
  Future<bool> selectAudioTrack(int trackId) async {
    final NativeVideoPlayerAudioTrack? track = _nativeAudioTracks
        ?.cast<NativeVideoPlayerAudioTrack?>()
        .firstWhere(
          (NativeVideoPlayerAudioTrack? t) => t?.index == trackId,
          orElse: () => null,
        );
    if (track == null) return false;
    await controller.setAudioTrack(track);
    selectedAudioTrackId = trackId;
    return true;
  }

  @override
  Future<bool> selectTextTrack(int? trackId) async {
    if (trackId == null) {
      // Unlike the AVPlay adapter, this plugin has a real "off".
      await controller.setSubtitleTrack(NativeVideoPlayerSubtitleTrack.off());
      selectedTextTrackId = null;
      return true;
    }
    final NativeVideoPlayerSubtitleTrack? track = _nativeTextTracks
        ?.cast<NativeVideoPlayerSubtitleTrack?>()
        .firstWhere(
          (NativeVideoPlayerSubtitleTrack? t) => t?.index == trackId,
          orElse: () => null,
        );
    if (track == null) return false;
    await controller.setSubtitleTrack(track);
    selectedTextTrackId = trackId;
    return true;
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    if (_isAndroid && _firstPlay) {
      _firstPlay = false;
      if (!_startupCancelled && _startupRevision != null) {
        await controller.playIfAndroidIntentUnchanged(_startupRevision!);
      }
      return;
    }
    await controller.play();
  }

  @override
  Future<void> pause() => controller.pause();

  @override
  Future<void> seekTo(Duration position) => controller.seekTo(position);

  @override
  void addListener(void Function(VideoplaybackValue) listener) {
    // Registering the same listener twice without an intervening
    // removeListener would otherwise silently overwrite its binding below,
    // orphaning the first StreamSubscription and its native activity
    // listener (leaked). Not currently reachable via VideoplaybackSession
    // (registers once, removes before disposing), but keep the adapter safe
    // standalone.
    if (_listeners.containsKey(listener)) return;

    void onActivity(PlayerActivityEvent event) {
      if (event.state == PlayerActivityState.error) {
        final String message =
            (event.data?['message'] as String?) ??
            streamingL10n.nativePlayerErrorNoDescription;
        if (message != _lastErrorMessage) {
          _lastErrorMessage = message;
          logPlayback('native_player failed', error: message);
        }
      }
      listener(value);
    }

    final StreamSubscription<Duration> position = controller.positionStream
        .listen((Duration _) => listener(value));
    controller.addActivityListener(onActivity);
    _listeners[listener] = (position: position, activity: onActivity);
  }

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {
    final _ListenerBinding? binding = _listeners.remove(listener);
    if (binding == null) return;
    unawaited(binding.position.cancel());
    controller.removeActivityListener(binding.activity);
  }

  @override
  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    _disposal.complete();
    _startupObserver?.dispose();
    _startupObserver = null;
    unawaited(controller.setAndroidPlayerRouteActive(false));
    // Defense in depth: clean up any binding still registered in case
    // removeListener was never called for it.
    for (final _ListenerBinding binding in _listeners.values) {
      unawaited(binding.position.cancel());
      controller.removeActivityListener(binding.activity);
    }
    _listeners.clear();
    return controller.dispose();
  }
}

/// Cancels startup intent only while the native owner has not initialized.
/// It never resumes playback or drives the native visibility policy.
class _AndroidStartupIntent with WidgetsBindingObserver {
  _AndroidStartupIntent() {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      cancelled = true;
    }
  }
  bool cancelled = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      cancelled = true;
      dispose();
    }
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}
