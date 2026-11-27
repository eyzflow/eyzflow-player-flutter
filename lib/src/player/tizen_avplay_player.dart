import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;

import '../core/source.dart';
import '../end_screen/end_screen.dart' show PlayerOverlayControls;
import '../end_screen/end_screen_view.dart';
import '../signals/stream_signals.dart';

import 'package:video_player_avplay/video_player.dart';
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as avplay;

import '../ads/ad_breaks.dart';
import '../ads/ad_countdown.dart';
import '../ads/ad_scheduler.dart';
import '../ads/vast_ad_driver.dart';
import '../ads/vast_loader.dart';
import '../bloc/player_controls_bloc.dart';
import '../bloc/videoplayer_feature_bloc.dart';
import 'ad_countdown_notice.dart';
import 'avplay_ad_player.dart';
import 'hls_renditions.dart';
import 'tv_ad_layer.dart';
import 'tv_canvas.dart';
import 'playback_event.dart';
import 'playback_event_emitter.dart';
import 'playback_target.dart';
import 'subtitle_preference_store.dart';
import 'player_controls.dart';
import 'player_options.dart';
import 'watch_progress_recorder.dart';
import 'player_log.dart';
import 'player_policy.dart';
import 'tizen_device_diagnostics.dart';
import 'widevine_license_client.dart';
import '../l10n/streaming_l10n.dart';
import 'player_loading_indicator.dart';

/// Widevine configuration for a source-backed target, and nothing for a
/// trailer.
///
/// PlayReady is never selected. `licenseServerUrl` stays null on purpose:
/// the native path hardcodes its own headers and cannot carry the
/// `access-token` credential, so the licence is fetched from Dart through
/// [licenseCallback] instead.
///
/// A trailer target is never DRM-protected — that's what its type already
/// says — so this never has to inspect `source.sourceType` to decide.
DrmConfigs? drmConfigsForTarget(
  VideoplayerTarget target,
  WidevineLicenseClient client,
) => switch (target) {
  VideoplayerTrailerTarget() => null,
  VideoplayerSourceTarget(:final source) =>
    source.drmAccessHeader == null
        ? null
        : DrmConfigs(
            type: DrmType.widevine,
            licenseCallback: (Uint8List challenge) => client.fetchLicense(
              challenge,
              licenseUri: source.widevineLicenseUrl,
              drmAccessHeader: source.drmAccessHeader!,
            ),
          ),
};

/// Selects the first text track accepted by the native AVPlay controller.
///
/// Returns the selected track, or `null` when there are no text tracks or the
/// native controller rejects the selection.
Future<TextTrack?> selectFirstTextTrack(
  List<TextTrack>? tracks,
  Future<bool> Function(TextTrack track) selectTrack,
) async {
  if (tracks == null || tracks.isEmpty) return null;

  final TextTrack firstTrack = tracks.first;
  return await selectTrack(firstTrack) ? firstTrack : null;
}

/// The audio track AVPlay is actually playing, from `getActiveTrackInfo`.
///
/// The plugin's `audioTracks` list carries no "is selected" flag — unlike the
/// Android plugin's — so without this the audio panel opened with no row
/// checked even though a language was plainly playing. `trackId` here is the
/// same `plusplayer::Track.index` the track list reports, so the id addresses
/// the same track.
///
/// Returns `null` when the native list holds no audio track, which is what
/// AVPlay answers before the track source is ready.
AudioTrack? activeAudioTrack(List<Track> tracks) {
  for (final Track track in tracks) {
    if (track is AudioTrack) return track;
  }
  return null;
}

/// Displays caption events emitted by the AVPlay controller.
///
/// AVPlay paints no subtitles of its own — the plugin pushes caption text up
/// to Dart and this widget draws it — so [isEnabled] is what "Off" means on
/// Tizen. There is no native call to make instead: the plugin's only lever is
/// `setTrackSelection`, which needs a track to select.
final class AvplaySubtitleOverlay extends StatelessWidget {
  const AvplaySubtitleOverlay({
    super.key,
    required this.controller,
    required this.isEnabled,
  });

  final VideoPlayerController controller;

  /// Whether the viewer has a subtitle track selected. The native track goes
  /// on decoding when they do not, and this is the only thing standing
  /// between its text and the screen.
  final bool isEnabled;

  @override
  Widget build(BuildContext context) {
    if (!isEnabled) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (BuildContext context, VideoPlayerValue value, Widget? child) {
        return ClosedCaption(captions: value.captions);
      },
    );
  }
}

/// Lays [child] out over the video's picture — the same centred, letterboxed
/// rect the video surface fills — lifted just enough to clear [bottomInset],
/// the controls' bottom bar measured from the bottom of the screen. Black
/// bars under the picture count towards it, so a wide film's subtitles move
/// only as far as they must.
@visibleForTesting
Widget captionsOverVideo({
  required double aspectRatio,
  required double bottomInset,
  required Widget child,
}) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final double width = constraints.maxWidth;
      final double height = constraints.maxHeight;
      final double pictureHeight = aspectRatio > 0
          ? (width / aspectRatio).clamp(0, height)
          : height;
      final double barBelow = (height - pictureHeight) / 2;
      final double lift = (bottomInset - barBelow).clamp(0, pictureHeight);
      return Center(
        child: AspectRatio(
          aspectRatio: aspectRatio > 0 ? aspectRatio : width / height,
          child: Padding(
            padding: EdgeInsets.only(bottom: lift),
            child: child,
          ),
        ),
      );
    },
  );
}

/// The single Tizen player. Owns one native controller per target.
class TizenAvplayPlayer extends StatefulWidget {
  const TizenAvplayPlayer({
    super.key,
    required this.target,
    this.createController,
    this.diagnostics,
    this.licenseClient,
    this.watchProgressRecorder,
    this.onPlaybackEvent,
    this.options = const PlayerOptions(),
    this.createAdPlayer,
    this.adClient,
    this.loadAdBreaks,
    this.loadSignals,
  });

  final VideoplayerTarget target;
  final VideoplaybackControllerFactory? createController;
  final TizenDeviceDiagnostics? diagnostics;

  /// Replaces reading the intro, recap and credits signals from the manifest.
  /// A test seam.
  final Future<List<StreamSignal>> Function(Uri master)? loadSignals;
  final WidevineLicenseClient? licenseClient;

  /// Replaces the AVPlay player an ad plays in. A test seam.
  final AdMediaPlayerFactory? createAdPlayer;

  /// Replaces the HTTP client for ad tags and tracking. A test seam.
  final http.Client? adClient;

  /// Replaces reading the ad break markers from the manifest. A test seam.
  final Future<List<AdBreak>> Function(Uri master)? loadAdBreaks;

  /// Records what the viewer watched. Absent in previews and tests, and for a
  /// trailer, which is not something a viewer resumes.
  final WatchProgressRecorder? watchProgressRecorder;

  /// Hears what playback does, for the host's analytics. Absent, nothing is
  /// observed and the player behaves exactly as it did without it. Every
  /// seek and track switch on Tizen goes through the controls overlay, so
  /// all of them are reported.
  final PlaybackEventCallback? onPlaybackEvent;

  /// A player config's theme and features for the overlay. `loop` does not
  /// apply: Tizen's player (PlusPlayer) cannot loop.
  ///
  /// With [PlayerOptions.ads] the player plays the tag's ads itself (there is
  /// no IMA for Tizen): see [VastAdDriver] and [TvAdLayer].
  final PlayerOptions options;

  @override
  State<TizenAvplayPlayer> createState() => _TizenAvplayPlayerState();
}

class _TizenAvplayPlayerState extends State<TizenAvplayPlayer> {
  VideoplaybackSession? _session;
  _AvplayController? _controller;

  /// One per session, so a replaced target closes its own sequence and the
  /// next one starts clean.
  PlaybackEventEmitter? _events;
  WidevineLicenseClient? _ownedLicenseClient;
  var _request = 0;

  /// The controller the session created, captured generically so the overlay
  /// works on both the real Tizen path and the test-injected path.
  VideoplaybackController? _playback;
  VideoplaybackTracks? _playbackTracks;
  PlayerControlsBloc? _controlsBloc;

  /// True once `session.start()` has returned (initialize + play settled or
  /// timed out). Gates the overlay so it does not flash before playback.
  bool _ready = false;
  bool _tickBridged = false;
  bool _tracksRequested = false;

  /// Ads for the current session, when the config has an ad tag.
  AdBreakScheduler? _ads;
  VastAdDriver? _adDriver;
  http.Client? _ownedAdClient;
  var _finishing = false;

  /// Seconds (the countdown's length … 1) until the next mid-roll while its
  /// notice shows.
  final ValueNotifier<int?> _adCountdown = ValueNotifier<int?>(null);
  VideoplaybackValue? _lastValue;
  Duration? _countdownPosition;

  http.Client get _adClient =>
      widget.adClient ?? (_ownedAdClient ??= http.Client());

  /// The intro, recap or credits signal playback is in.
  final SignalTracker _signals = SignalTracker();

  /// Where playback is, for the overlay layer (end screen, app overlay).
  final ValueNotifier<PlaybackFacts> _facts = ValueNotifier<PlaybackFacts>(
    const PlaybackFacts(),
  );

  /// Whether the overlay layer shows something: the skip button stays away.
  final PlayerOverlayState _overlay = PlayerOverlayState();

  void _onOverlayChanged() {
    if (mounted) setState(() {});
  }

  WidevineLicenseClient get _licenseClient =>
      widget.licenseClient ?? (_ownedLicenseClient ??= WidevineLicenseClient());

  @override
  void initState() {
    super.initState();
    _overlay.addListener(_onOverlayChanged);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(TizenAvplayPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _events?.onEvent = widget.onPlaybackEvent;
    if (oldWidget.target != widget.target) {
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
    final VideoplaybackSession? retiredSession = _session;
    await retiredSession?.dispose();
    if (!mounted ||
        request != _request ||
        !identical(_session, retiredSession)) {
      return;
    }
    _session = null;
    _controller = null;
    unawaited(_controlsBloc?.close() ?? Future<void>.value());
    _controlsBloc = null;
    _playback = null;
    _playbackTracks = null;
    _ready = false;
    _tickBridged = false;
    _tracksRequested = false;
    await _start();
  }

  Future<void> _start() async {
    final WatchProgressRecorder? recorder = widget.watchProgressRecorder;
    final TizenDeviceDiagnostics? diagnostics =
        widget.diagnostics ?? getTizenDeviceDiagnosticsOrNull();
    if (diagnostics != null) unawaited(diagnostics.logDeviceOnce());
    final PlaybackEventEmitter events = PlaybackEventEmitter(
      sourceId: switch (widget.target) {
        VideoplayerTrailerTarget(:final source) => source.id,
        VideoplayerSourceTarget(:final source) => source.id,
      },
      onEvent: widget.onPlaybackEvent,
    );
    _events = events;
    _finishing = false;
    final Future<HlsMarkers> markers = _loadMarkers(_hlsMaster(widget.target));
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
        _signals.position(value.isCompleted ? null : value.position);
        _facts.value = PlaybackFacts(
          position: value.position,
          duration: value.duration,
          playing: value.isPlaying,
          ended: value.isCompleted,
        );
      },
      // The controller opens at the resume position itself; see
      // [_createAvplayController].
      seeksToResumePosition: false,
    );
    _session = session;
    if (ads != null) {
      // Before the film's player exists: a TV has one video decoder, and
      // the ad needs it. The pre-roll's time is not the film's startup.
      await ads.beforeContent();
      if (!mounted || !identical(_session, session)) return;
    }
    await session.start();
    if (mounted && identical(_session, session)) {
      setState(() => _ready = true);
    }
  }

  /// The ads scheduler for a new session, or null without an ad tag. The
  /// markers are read from the manifest while the player starts.
  AdBreakScheduler? _setUpAds(
    PlaybackEventEmitter events,
    Future<HlsMarkers> markers,
  ) {
    _disposeAds();
    final PlayerAds? ads = widget.options.ads;
    if (ads == null) return null;
    final http.Client client = _adClient;
    final AdPing ping = httpAdPing(client);
    final VastAdDriver driver = _adDriver = VastAdDriver(
      adTagUrl: ads.adTagUrl,
      loader: VastLoader(client: client, ping: ping),
      createPlayer: widget.createAdPlayer ?? AvplayAdMediaPlayer.new,
      ping: ping,
      onPauseContent: () => unawaited(_pauseForAd()),
      onResumeContent: () => unawaited(_resumeAfterAd()),
      onReleaseContent: () => unawaited(_releaseForPostroll()),
      contentDuration: () => _playback?.value.duration,
    );
    final AdBreakScheduler scheduler = AdBreakScheduler(
      ads: ads,
      driver: driver,
      onBreakStarted: events.adBreakStarted,
      onBreakEnded: events.adBreakEnded,
    )..addListener(_onAdsChanged);
    driver.scheduler = scheduler;
    _ads = scheduler;
    final Uri master = _hlsMaster(widget.target);
    unawaited(
      ads.loadMarkers(() async {
        final Future<List<AdBreak>> Function(Uri)? load = widget.loadAdBreaks;
        if (load != null) return load(master);
        return (await markers).adBreaks;
      }),
    );
    return scheduler;
  }

  /// The film stops for a mid-roll and lets go of the video decoder, so the
  /// ad's player can have it.
  Future<void> _pauseForAd() async {
    final VideoplaybackController? playback = _playback;
    if (playback is _AvplayController) {
      await playback.releaseForAd();
    } else {
      await playback?.pause();
    }
  }

  Future<void> _resumeAfterAd() async {
    final VideoplaybackController? playback = _playback;
    if (playback is _AvplayController) await playback.restoreAfterAd();
    await playback?.play();
  }

  /// The film ended and a post-roll plays: the decoder goes to the ad, and
  /// the film is not resumed.
  Future<void> _releaseForPostroll() async {
    final VideoplaybackController? playback = _playback;
    if (playback is _AvplayController) await playback.releaseForAd();
  }

  void _onAdsChanged() {
    if (mounted) setState(() {});
    _updateAdCountdown(_lastValue, jumped: false);
  }

  /// The notice before a mid-roll, from the latest position report. Hidden
  /// while paused or buffering, right after a seek, while scrubbing or
  /// previewing on the seek bar, and during an ad break.
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
            remote: false,
            position: position,
            starts: ads.upcomingMidrolls,
            length: widget.options.adCountdownSeconds,
          );
  }

  void _disposeAds() {
    final AdBreakScheduler? ads = _ads;
    final VastAdDriver? driver = _adDriver;
    _adCountdown.value = null;
    _lastValue = null;
    _countdownPosition = null;
    _ads = null;
    _adDriver = null;
    ads?.removeListener(_onAdsChanged);
    ads?.dispose();
    driver?.dispose();
  }

  Future<VideoplaybackController> _createAndCaptureController(
    VideoplayerTarget target,
  ) async {
    final VideoplaybackController controller =
        await (widget.createController ?? _createAvplayController)(target);
    _playback = controller;
    // The cast is not redundant: the ternary's static type is the LUB of the
    // promoted type and Null, which drops back to VideoplaybackController?.
    _playbackTracks = controller is VideoplaybackTracks
        ? controller as VideoplaybackTracks
        : null;
    return controller;
  }

  Future<VideoplaybackController> _createAvplayController(
    VideoplayerTarget target,
  ) async {
    // HLS, always, proven on hardware 2026-08-26. Both manifests address the
    // same encrypted segment files with the same `KEYID`s, and the HLS
    // playlists carry an inline Widevine `pssh`, so the same licence unlocks
    // either — but only HLS signals a clear lead-in
    // (`EXT-X-DISCONTINUITY` + a late `EXT-X-KEY`), which the DASH path could
    // not follow. DASH played no film; HLS plays them. FairPlay never enters
    // it: `DrmType` offers only none/playready/widevine.
    //
    // See docs/superpowers/specs/
    // 2026-08-19-flutter-tizen-avplay-widevine-findings.md.
    final EYZFlowSource source = switch (target) {
      VideoplayerTrailerTarget(:final source) => source,
      VideoplayerSourceTarget(:final source) => source,
    };
    final String url = source.hlsStreamUrl.toString();

    final DrmConfigs? drmConfigs = drmConfigsForTarget(target, _licenseClient);
    if (kDebugMode) {
      logPlayback(
        'source.prepare url=$url (hls, '
        'drm ${drmConfigs?.type.name ?? 'none'})',
      );
    }
    // PlusPlayer seeks to `startPosition` before PrepareAsync, so the decoder
    // and the licence come up at the resume point. Seeking the paused player
    // after initialize instead failed the hardware decoder mid-seek
    // (OpenMAX "not data output") on resumed films.
    final Duration? resumeAt = resumePositionFor(target);
    if (resumeAt != null) logPlayback('opening at $resumeAt');
    final _AvplayController controller = _AvplayController(
      VideoPlayerController.network(
        url,
        formatHint: avplay.VideoFormat.hls,
        drmConfigs: drmConfigs,
        playerOptions: <String, dynamic>{
          if (resumeAt != null) 'startPosition': resumeAt.inMilliseconds,
        },
      ),
    );
    _controller = controller;
    return controller;
  }

  void _finished() {
    // Recorded before the bloc tears the session down, so the completion is
    // written even though the view is about to go away.
    widget.watchProgressRecorder?.finish();
    final AdBreakScheduler? ads = _ads;
    if (ads == null) {
      _close();
      return;
    }
    // A VMAP's post-roll plays before the player closes.
    if (_finishing) return;
    _finishing = true;
    unawaited(ads.contentCompleted().whenComplete(_close));
  }

  void _close() {
    // The player stays on the end screen when there is one.
    if (mounted && !endScreenAtTheEnd(context)) {
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
    if (mounted) {
      context.read<VideoplayerFeatureBloc>().add(
        VideoplayerFeatureSourceFailed(message),
      );
    }
  }

  @override
  void dispose() {
    _request++;
    _disposeAds();
    _signals.dispose();
    _overlay.removeListener(_onOverlayChanged);
    _overlay.dispose();
    _facts.dispose();
    _closeEvents();
    unawaited(_session?.dispose() ?? Future<void>.value());
    unawaited(_controlsBloc?.close() ?? Future<void>.value());
    _ownedLicenseClient?.close();
    _ownedAdClient?.close();
    _adCountdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = _buildContent(context);
    if (widget.options.ads == null) return content;
    // One Stack from the first frame, the film at index 0, so the ads
    // coming and going never re-parent the video.
    final AdBreakScheduler? ads = _ads;
    final VastAdDriver? driver = _adDriver;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        content,
        // Over the video and the controls, never focusable: it stays up
        // while the controls are hidden.
        // Both on the TV canvas, like the controls: sized for Android TV's
        // 960 logical pixels, scaled up to the TV's width.
        if (ads != null && widget.options.adCountdown)
          TvCanvas(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                AdCountdownNotice(
                  seconds: _adCountdown,
                  // Up out of the skip button's way while one shows.
                  liftedBy: widget.options.skipButtons && !_overlay.active
                      ? _signals
                      : null,
                ),
              ],
            ),
          ),
        if (ads != null && driver != null)
          TvCanvas(
            child: TvAdLayer(
              scheduler: ads,
              driver: driver,
              theme: widget.options.controlsTheme,
              onBack: () => _closeFromControls(context),
            ),
          ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    final VideoplaybackController? playback = _playback;
    final VideoplaybackTracks? tracks = _playbackTracks;
    if (!_ready || playback == null || tracks == null) {
      return const Center(child: PlayerLoadingIndicator(isTv: true));
    }

    final PlayerControlsBloc bloc = _ensureControlsBloc(playback, tracks);
    _loadTracksOnce(tracks, bloc);

    final EYZFlowSource source = switch (widget.target) {
      VideoplayerTrailerTarget(:final source) => source,
      VideoplayerSourceTarget(:final source) => source,
    };
    final String title = source.title;
    final bool inAdBreak = _ads?.inBreak ?? false;

    return BlocProvider<PlayerControlsBloc>.value(
      value: bloc,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PlayerOverlayLayer(
            surface: _buildVideoSurface(bloc),
            signal: _signals,
            facts: _facts,
            inAdBreak: inAdBreak,
            state: _overlay,
            theme: widget.options.controlsTheme,
            remote: true,
            controls: PlayerOverlayControls(
              skip: _skipSignal,
              seek: (Duration position) {
                _signals.seeked(position);
                unawaited(playback.seekTo(position));
              },
              play: () => unawaited(playback.play()),
              pause: () => unawaited(playback.pause()),
              dismiss: () {},
            ),
          ),
          // Hidden and out of the remote's reach during an ad break: no
          // focus, so no seek, no track panel. Kept alive for after it.
          Visibility(
            visible: !inAdBreak,
            maintainState: true,
            child: ExcludeFocus(
              excluding: inAdBreak,
              child: PlayerControls(
                title: title,
                thumbnailsUrl: source.thumbnailsUrl,
                onBack: () => _closeFromControls(context),
                theme: widget.options.controlsTheme,
                showControls: widget.options.controls,
                signal: _signals,
                onSkipSignal: _skipSignal,
                skipButton: widget.options.skipButtons && !_overlay.active,
                skipButtonTypes: widget.options.skipButtonTypes,
                captionsBuilder: _buildCaptions,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The real video only exists on the Tizen path, where `_controller` holds
  /// the plugin controller. In host tests there is none, so this is a black
  /// fill under the overlay.
  Widget _buildVideoSurface(PlayerControlsBloc bloc) {
    final VideoPlayerController? controller = _controller?.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    _bridgeTick(controller, bloc);
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  /// The subtitles, which the controls draw over the video and keep above
  /// their bottom bar while they show (see [captionsOverVideo]). None while
  /// the end screen or the app's overlay has the video shrunk into a corner,
  /// as on the web player.
  Widget _buildCaptions(BuildContext context, double bottomInset) {
    final VideoPlayerController? controller = _controller?.controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _overlay.active) {
      return const SizedBox.shrink();
    }
    return captionsOverVideo(
      aspectRatio: controller.value.aspectRatio,
      bottomInset: bottomInset,
      // AVPlay paints no subtitles of its own — the plugin pushes caption
      // text up to Dart and this overlay draws it — so not drawing it is what
      // "Off" means here. There is no native "disable text" call to make
      // instead: the plugin's only lever is `setTrackSelection`, which needs
      // a track to select.
      child: BlocSelector<PlayerControlsBloc, PlayerControlsState, bool>(
        // Off still draws a forced track (the lines in another language).
        selector: (PlayerControlsState state) =>
            state.selectedTextTrackId != null ||
            state.forcedTextTrackId != null,
        builder: (BuildContext context, bool isEnabled) =>
            AvplaySubtitleOverlay(controller: controller, isEnabled: isEnabled),
      ),
    );
  }

  PlayerControlsBloc _ensureControlsBloc(
    VideoplaybackController playback,
    VideoplaybackTracks tracks,
  ) {
    return _controlsBloc ??= PlayerControlsBloc(
      controller: playback,
      tracks: tracks,
      subtitlePreferenceStore: getSubtitlePreferenceStoreOrNull(),
      hidesWhenIdle: widget.options.autoHideControls,
      // Playback starts on its own: the film opens without the overlay,
      // unless the config keeps the controls up.
      startsHidden: widget.options.autoHideControls,
      captions: widget.options.captions,
      onSeeked: (Duration from, Duration to) {
        _events?.seeked(from, to);
        // A seek by the viewer ends a skip: back in the intro, the button
        // shows again.
        _signals.seeked(to);
      },
      onAudioTrackChanged: _events?.audioTrackChanged,
      onSubtitleTrackChanged: _events?.subtitleTrackChanged,
    );
  }

  /// Bridges the plugin controller's ticks into the Bloc. `isPlaying` and
  /// `isBuffering` come only from the plugin's `VideoPlayerValue`, so this runs
  /// on the real path only. Separate from the `VideoplaybackSession` listener
  /// that records watch progress, so neither disturbs the other.
  /// The stream's ad break markers and signals, read once per session from
  /// the playlist AVPlay loads. None when it cannot be read.
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
    if (signal == null || playback == null) return;
    final Duration? duration = playback.value.duration;
    final Duration target = duration != null && signal.end > duration
        ? duration
        : signal.end;
    _events?.seeked(playback.value.position ?? signal.start, target);
    _signals.skipped(signal, target);
    unawaited(playback.seekTo(target));
  }

  void _bridgeTick(VideoPlayerController controller, PlayerControlsBloc bloc) {
    if (_tickBridged) return;
    _tickBridged = true;
    void listener() {
      if (bloc.isClosed) return;
      final VideoPlayerValue value = controller.value;
      if (!value.isInitialized) return;
      bloc.add(
        PlayerControlsValueTicked(
          position: value.position,
          duration: value.duration.end,
          isPlaying: value.isPlaying,
        ),
      );
      bloc.add(PlayerControlsBufferingChanged(value.isBuffering));
    }

    controller.addListener(listener);
  }

  Future<void> _loadTracksOnce(
    VideoplaybackTracks tracks,
    PlayerControlsBloc bloc,
  ) async {
    if (_tracksRequested) return;
    _tracksRequested = true;
    final annotated = await annotateHlsTracks(
      switch (widget.target) {
        VideoplayerTrailerTarget(:final source) => source.hlsStreamUrl,
        VideoplayerSourceTarget(:final source) => source.hlsStreamUrl,
      },
      await tracks.audioTracks(),
      await tracks.textTracks(),
    );
    if (!mounted || bloc.isClosed) return;
    bloc.add(
      PlayerControlsTracksLoaded(
        audioTracks: annotated.audio,
        textTracks: annotated.text,
        forcedTextTracks: annotated.forcedText,
      ),
    );
  }

  void _closeFromControls(BuildContext context) {
    context.read<VideoplayerFeatureBloc>().add(
      const VideoplayerFeaturePlaybackFinished(),
    );
  }
}

final class _AvplayController
    implements VideoplaybackController, VideoplaybackTracks {
  _AvplayController(this.controller);

  final VideoPlayerController controller;
  final Map<void Function(VideoplaybackValue), void Function()> _listeners =
      <void Function(VideoplaybackValue), void Function()>{};

  int? _selectedAudioTrackId;
  int? _selectedTextTrackId;

  /// The text track the native player is decoding, which is not the same as
  /// the one the overlay draws: `Off` leaves the native selection alone,
  /// because there is nothing to deselect it with. Turning that same language
  /// back on is then a display change only, and must not re-issue a selection
  /// the player is already running.
  int? _nativeTextTrackId;

  @override
  VideoplaybackValue get value => _value(controller.value);

  @override
  Future<void> seekTo(Duration position) => controller.seekTo(position);

  @override
  Future<void> initialize() async {
    await controller.initialize();
    // What the streaming engine actually resolved. A missing video track is
    // the difference between "black screen with sound" and "nothing at all",
    // and the GStreamer criticals do not say which happened.
    final VideoPlayerValue value = controller.value;
    logPlayback(
      'after initialize: isInitialized ${value.isInitialized}, '
      'size ${value.size}, duration ${value.duration}, '
      'has_error ${value.errorDescription != null}',
    );
    // Each getter answers null before initialization; awaited separately so one
    // native failure does not hide the other two.
    for (final (String label, Future<List<Object?>?> tracks)
        in <(String, Future<List<Object?>?>)>[
          ('video', controller.videoTracks),
          ('audio', controller.audioTracks),
        ]) {
      try {
        logPlayback('$label tracks count=${(await tracks)?.length ?? 0}');
      } on Object catch (error) {
        logPlayback('$label tracks unavailable', error: error);
      }
    }
    try {
      final AudioTrack? active = activeAudioTrack(
        await controller.getActiveTrackInfo(),
      );
      if (active != null) {
        _selectedAudioTrackId = active.trackId;
        logPlayback(
          'active audio track: id ${active.trackId}, '
          'language ${active.language}',
        );
      } else {
        logPlayback('no active audio track reported');
      }
    } on Object catch (error) {
      logPlayback('active track info unavailable', error: error);
    }
    try {
      final List<TextTrack>? textTracks = await controller.textTracks;
      logPlayback('text tracks count=${textTracks?.length ?? 0}');
      final TextTrack? selectedTrack = await selectFirstTextTrack(
        textTracks,
        controller.setTrackSelection,
      );
      if (selectedTrack != null) {
        _selectedTextTrackId = selectedTrack.trackId;
        _nativeTextTrackId = selectedTrack.trackId;
        logPlayback(
          'selected first text track: id ${selectedTrack.trackId}, '
          'language ${selectedTrack.language}',
        );
      } else if (textTracks?.isNotEmpty ?? false) {
        logPlayback('first text track selection failed');
      }
    } on Object catch (error) {
      logPlayback('text tracks unavailable', error: error);
    }
  }

  @override
  Future<void> play() => controller.play();

  @override
  Future<void> pause() => controller.pause();

  /// Pauses and lets go of the video decoder for an ad's player (PlusPlayer
  /// `Deactivate`, the plugin's way to run two players). A model that
  /// refuses is logged: the ad then fails to start, and the film resumes.
  Future<void> releaseForAd() async {
    await controller.pause();
    try {
      if (!await controller.deactivate()) {
        logPlayback('film player did not release its decoder for the ad');
      }
    } on Object catch (error) {
      logPlayback('film player deactivate failed', error: error);
    }
  }

  /// Takes the decoder back after an ad. The caller plays.
  Future<void> restoreAfterAd() async {
    try {
      if (!await controller.activate()) {
        logPlayback('film player did not get its decoder back');
      }
    } on Object catch (error) {
      logPlayback('film player activate failed', error: error);
    }
  }

  @override
  int? get selectedAudioTrackId => _selectedAudioTrackId;

  @override
  int? get selectedTextTrackId => _selectedTextTrackId;

  // ponytail: each selection re-fetches the native track list, so a selection
  // is two plugin calls instead of one. Deliberate: the plugin answers `null`
  // for both lists until the streaming engine resolves them, so memoising the
  // first answer would cache an empty list and blank the panels. Cache only
  // once there is a hardware-verified signal for "tracks are final" — see
  // PR #107 issue 6. The Android adapter caches safely because it reads only
  // after initialize() and load() have completed.
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async {
    try {
      final List<AudioTrack>? tracks = await controller.audioTracks;
      return tracks == null
          ? const <PlayerAudioTrack>[]
          : <PlayerAudioTrack>[
              for (final AudioTrack track in tracks)
                PlayerAudioTrack(
                  trackId: track.trackId,
                  language: track.language,
                  channel: track.channel,
                ),
            ];
    } on Object catch (error) {
      logPlayback('audio tracks unavailable', error: error);
      return const <PlayerAudioTrack>[];
    }
  }

  @override
  Future<List<PlayerTextTrack>> textTracks() async {
    try {
      final List<TextTrack>? tracks = await controller.textTracks;
      return tracks == null
          ? const <PlayerTextTrack>[]
          : <PlayerTextTrack>[
              for (final TextTrack track in tracks)
                PlayerTextTrack(
                  trackId: track.trackId,
                  language: track.language,
                ),
            ];
    } on Object catch (error) {
      logPlayback('text tracks unavailable', error: error);
      return const <PlayerTextTrack>[];
    }
  }

  @override
  Future<bool> selectAudioTrack(int trackId) async {
    try {
      final List<AudioTrack>? tracks = await controller.audioTracks;
      final AudioTrack? track = tracks?.cast<AudioTrack?>().firstWhere(
        (AudioTrack? t) => t?.trackId == trackId,
        orElse: () => null,
      );
      if (track == null) return false;
      final bool ok = await controller.setTrackSelection(track);
      if (ok) _selectedAudioTrackId = trackId;
      return ok;
    } on Object catch (error) {
      logPlayback('audio track selection failed', error: error);
      return false;
    }
  }

  @override
  Future<bool> selectTextTrack(int? trackId) async {
    try {
      if (trackId == null) {
        // Off is a display state, and the caption overlay is what reads it:
        // the native track keeps decoding because the plugin offers no way to
        // turn it off, and nothing draws its text.
        _selectedTextTrackId = null;
        return true;
      }
      if (trackId == _nativeTextTrackId) {
        // Already the decoding track — this is Off being lifted, so only the
        // overlay changes.
        _selectedTextTrackId = trackId;
        return true;
      }
      final List<TextTrack>? tracks = await controller.textTracks;
      final TextTrack? track = tracks?.cast<TextTrack?>().firstWhere(
        (TextTrack? t) => t?.trackId == trackId,
        orElse: () => null,
      );
      if (track == null) return false;
      final bool ok = await controller.setTrackSelection(track);
      if (ok) {
        _selectedTextTrackId = trackId;
        _nativeTextTrackId = trackId;
      }
      return ok;
    } on Object catch (error) {
      logPlayback('text track selection failed', error: error);
      return false;
    }
  }

  /// Last native error already logged, so a per-tick notification logs once.
  String? _loggedError;

  @override
  void addListener(void Function(VideoplaybackValue) listener) {
    void nativeListener() {
      final VideoPlayerValue value = controller.value;
      final String? description = value.hasError
          ? value.errorDescription ??
                streamingL10n.nativePlayerErrorNoDescription
          : null;
      if (description != null && description != _loggedError) {
        _loggedError = description;
        logPlayback('native playback failed', error: description);
        logPlayback(
          'native failure position_ms=${value.position.inMilliseconds} initialized=${value.isInitialized}',
        );
      }
      listener(_value(value, errorMessage: description));
    }

    _listeners[listener] = nativeListener;
    controller.addListener(nativeListener);
  }

  @override
  void removeListener(void Function(VideoplaybackValue) listener) {
    final void Function()? nativeListener = _listeners.remove(listener);
    if (nativeListener != null) controller.removeListener(nativeListener);
  }

  @override
  Future<void> dispose() => controller.dispose();

  /// Bridges the plugin's value into the package-owned one, so nothing outside
  /// this adapter depends on a plugin type.
  VideoplaybackValue _value(VideoPlayerValue value, {String? errorMessage}) {
    return VideoplaybackValue(
      isCompleted: value.isCompleted,
      errorMessage: errorMessage,
      position: value.isInitialized ? value.position : null,
      // The plugin reports a range; playback length is its end.
      duration: value.isInitialized ? value.duration.end : null,
      // Carried for playback events; nothing else reads them off this value
      // (the overlay takes its own from the plugin in [_bridgeTick]).
      // `isPlaying` here is the request to play, and stays true through a
      // stall, so not playing is paused unless playback is over.
      isPlaying: value.isPlaying,
      isBuffering: value.isBuffering,
      isPaused:
          value.isInitialized &&
          !value.isPlaying &&
          !value.isCompleted &&
          !value.hasError,
    );
  }
}

Uri _hlsMaster(VideoplayerTarget target) => switch (target) {
  VideoplayerTrailerTarget(:final source) => source.hlsStreamUrl,
  VideoplayerSourceTarget(:final source) => source.hlsStreamUrl,
};
