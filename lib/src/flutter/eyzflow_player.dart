import 'dart:async';

import '../core/source.dart';
import '../core/usage_reporter.dart';
import '../end_screen/end_screen.dart';
import '../player/playback_event.dart';
import '../player/playback_target.dart';
import '../player/watch_progress_recorder.dart';
import '../videoplayer_feature.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../ads/ad_tag.dart';
import '../cast/cast_backend.dart';
import '../cast/cast_controller.dart';
import '../cast/cast_media.dart';
import '../cast/cast_picker.dart';
import '../cast/casting_view.dart';
import '../core/analytics/transport.dart';
import '../core/api.dart';
import '../core/device_id.dart';
import '../core/playback_session.dart';
import '../core/player_config.dart';
import '../core/player_license.dart';
import '../l10n/player_language.dart';
import '../l10n/streaming_l10n.dart';
import '../player/player_options.dart';
import 'device_context.dart';
import 'error_view.dart';
import 'playback_coordinator.dart';

typedef EYZFlowPlayerErrorBuilder =
    Widget Function(
      BuildContext context,
      EYZFlowPlayerFailure failure,
      VoidCallback close,
    );

/// The EYZFlow player for Flutter apps: the
/// [VideoplayerFeatureView], with the web player's player key check,
/// stream and device limits, and playback quality analytics around it.
///
/// Fullscreen, like the view it wraps: push it as a route.
///
/// ```dart
/// Navigator.of(context).push(MaterialPageRoute<void>(
///   fullscreenDialog: true,
///   builder: (_) => EYZFlowPlayer(
///     streamId: streamId,
///     title: title,
///     sourceType: EYZFlowFilm(catalogueId),
///     drmAuthorization: 'Bearer $accessToken',
///     storefrontId: storefrontId,
///     playerKey: 'pk_…',
///     isTv: isTv,
///   ),
/// ));
/// ```
class EYZFlowPlayer extends StatefulWidget {
  const EYZFlowPlayer({
    super.key,
    required this.streamId,
    required this.title,
    this.description,
    this.poster,
    this.sourceType,
    this.progressSeconds,
    this.isTv = false,
    this.playerKey,
    this.configId,
    this.config,
    this.drmAuthorization,
    this.storefrontId,
    this.drmParameters = const {},
    this.offerId,
    this.deviceName,
    this.appId,
    this.analytics = true,
    this.watchProgressStore,
    this.language,
    this.onLimitReached,
    this.onLicenseError,
    this.onError,
    this.onReady,
    this.onSignal,
    this.endScreen,
    this.overlayBuilder,
    this.onCloseRequested,
    this.onPlaybackEvent,
    this.errorBuilder,
    this.endpoints = const EYZFlowEndpoints(),
    this.httpClient,
    this.deviceIdStore,
    this.beatSender,
    this.usageSender,
    this.playerBuilder,
    this.castReceiverAppId,
    this.enableCast = true,
    this.castBackend,
    this.debugOperatingSystemOverride,
  });

  /// The stream's id (not the catalogue id).
  final String streamId;
  final String title;
  final String? description;
  final Uri? poster;

  /// [EYZFlowFilm] plays with DRM and a playback session;
  /// [EYZFlowTrailer] (or null) plays without either.
  final EYZFlowSourceType? sourceType;

  /// Where to resume, in seconds.
  final double? progressSeconds;

  /// Whether the host runs as a TV app. Selects the TV route and the
  /// `androidtv` platform.
  final bool isTv;

  /// `pk_…`, from the dashboard's Player → Keys. Without it there is no key
  /// check and no analytics. Each app must be on the key's allowed apps.
  final String? playerKey;

  /// A player config from the dashboard (Player → Configs), `cfg_…`. Loaded
  /// before playback starts (and kept in memory for the app's life); when it
  /// cannot be loaded the player plays with its defaults. Also sent with the
  /// player key check. What applies on which platform: see the README.
  final String? configId;

  /// Inline config, merged over the one [configId] loads: what is given here
  /// wins, as with the web player's `config` prop. Read when playback starts,
  /// except `features.adCountdown` and `ads.countdownSeconds`, which apply
  /// while playing.
  final PlayerConfigOverride? config;

  /// The viewer's `Authorization`, e.g. `Bearer <token>`. Needed for DRM and
  /// playback sessions.
  final String? drmAuthorization;

  /// The storefront the viewer watches on (else the config's
  /// `drm.parameters.storefront_id`). Opens a playback session, so the plan's
  /// stream and device limits apply.
  final String? storefrontId;

  /// Extra DRM access-token parameters, e.g. `{'source': 'internal'}`. Merged
  /// over the config's `drm.parameters`; these win.
  final Map<String, Object?> drmParameters;

  /// The offer (film or episode) [streamId] plays. With [drmAuthorization]
  /// and a storefront, the player reports the seconds the viewer watched for
  /// licensor royalties. Trailers, and a film the end screen picked, report
  /// nothing.
  final String? offerId;

  /// Shown in the viewer's device list, e.g. "Living room TV".
  final String? deviceName;

  /// The app's package name or bundle id for the key check. Read from the
  /// platform when null.
  final String? appId;

  /// False turns beats off even when the key has analytics on.
  final bool analytics;

  /// Where watch progress is saved (films only), e.g. the app's watch
  /// history. Null records nothing.
  final WatchProgressStore? watchProgressStore;

  /// The language of the player's own text (`en`, `de`, `fr`, `nl`), e.g.
  /// the storefront's. Null keeps [eyzflowPlayerLanguage]: the one set with
  /// [setEYZFlowPlayerLanguage], else the device's.
  final String? language;

  final ValueChanged<PlaybackLimitError>? onLimitReached;
  final ValueChanged<PlayerLicenseError>? onLicenseError;

  /// Every failure the viewer sees, as text.
  final ValueChanged<String>? onError;

  /// The player is initialized.
  final VoidCallback? onReady;

  /// Playback entered an intro, recap or credits signal marked on the stream
  /// (Stream → Signals), or left one (null). For example, offer the next
  /// episode when [StreamSignalType.closingCredits] starts. The same as the
  /// [PlaybackSignalStarted] and [PlaybackSignalEnded] events.
  final ValueChanged<StreamSignal?>? onSignal;

  /// The built-in end screen: "Up next" with a countdown and a row of films
  /// you pass, over the closing credits (the video shrunk into a corner) or
  /// after the film. A picked film plays in place, with its own key check,
  /// session and DRM; [EYZFlowEndScreen.onSelect] hears it and can prevent
  /// it. The config's `features.endScreen` and `endScreen` settings apply
  /// where it leaves them out.
  final EYZFlowEndScreen? endScreen;

  /// Your own UI over the player at a signal or after the end, e.g. similar
  /// films at the closing credits. It wins over [endScreen] when it returns a
  /// widget.
  final PlayerOverlayBuilder? overlayBuilder;

  /// Closing; [Navigator.pop] when null.
  final VoidCallback? onCloseRequested;

  /// Every playback event, for the host's own analytics.
  final PlaybackEventCallback? onPlaybackEvent;

  /// Replaces the built-in failure screen.
  final EYZFlowPlayerErrorBuilder? errorBuilder;

  /// Moves the key check, sessions and beats. Stream and DRM licence URLs come
  /// from [EYZFlowSource] and stay on production.
  final EYZFlowEndpoints endpoints;
  final http.Client? httpClient;
  final DeviceIdStore? deviceIdStore;

  /// Replaces the beat upload, e.g. to log beats in a test app.
  final BeatSender? beatSender;

  /// Replaces the royalty report upload, e.g. to log reports in a test app.
  final UsageSender? usageSender;

  /// Replaces the player surface, as [VideoplayerFeatureView.playerBuilder]
  /// does. A test seam.
  final VideoplayerFeaturePlayerBuilder? playerBuilder;

  /// The EYZFlow Cast receiver's app id from the Google Cast console
  /// (`cast-receiver/`), else the config's `cast.receiverAppId`. Films cast
  /// only with it: Google's default receiver cannot add the DRM access token.
  /// Without it only trailers cast.
  final String? castReceiverAppId;

  /// Offers Chromecast on Android and iOS phones and tablets when a Cast
  /// device is on the network. Never on TV. A config with
  /// `features.chromecast: false` turns it off too.
  final bool enableCast;

  /// Replaces the Chromecast client. A test seam.
  final CastBackend? castBackend;

  /// Forces the operating system (`android`, `ios`, `tizen`). A test seam;
  /// production reads the real platform.
  final String? debugOperatingSystemOverride;

  @override
  State<EYZFlowPlayer> createState() => _EYZFlowPlayerState();
}

class _EYZFlowPlayerState extends State<EYZFlowPlayer> {
  PlaybackCoordinator? _coordinator;
  http.Client? _ownedClient;
  WatchProgressRecorder? _recorder;
  EYZFlowSource? _source;
  late final AppLifecycleListener _lifecycle;

  /// Chromecast, on phones and tablets.
  EYZFlowCastController? _cast;

  /// Bumped to mount a fresh player, e.g. when casting hands playback back.
  var _playerGeneration = 0;
  CastPlayerState? _castPlayerState;
  var _closing = false;

  /// The config playback started with: [EYZFlowPlayer.configId]'s, under the
  /// inline [EYZFlowPlayer.config].
  PlayerConfig _config = PlayerConfig.defaults;

  /// A film the end screen picked: it plays in place of `widget.streamId`
  /// until the app passes another one.
  EYZFlowEndScreenItem? _picked;

  String get _streamId => _picked?.streamId ?? widget.streamId;

  EYZFlowSourceType? get _sourceType {
    final EYZFlowEndScreenItem? picked = _picked;
    if (picked == null) return widget.sourceType;
    return picked.sourceType ??
        (widget.sourceType is EYZFlowFilm
            ? EYZFlowFilm(picked.streamId)
            : EYZFlowTrailer(picked.streamId));
  }

  bool get _isProtected => _sourceType is EYZFlowFilm;

  /// Plays an end screen item in place: a new key check, session and DRM.
  void _pick(EYZFlowEndScreenItem item) {
    if (!mounted) return;
    setState(() => _picked = item);
    _stop();
    unawaited(_start());
  }

  PlayerOptions _options = const PlayerOptions();

  /// The config [EYZFlowPlayer.configId] loaded, if any.
  PlayerConfig? _remoteConfig;

  /// The receiver films cast to: the widget's, else the config's.
  String? get _castReceiverAppId =>
      widget.castReceiverAppId ?? _config.castReceiverAppId;

  @override
  void initState() {
    super.initState();
    final String? language = widget.language;
    if (language != null) setEYZFlowPlayerLanguage(language);
    _lifecycle = AppLifecycleListener(
      onHide: () => _coordinator?.onBackgrounded(),
    );
    unawaited(_start());
  }

  @override
  void didUpdateWidget(EYZFlowPlayer old) {
    super.didUpdateWidget(old);
    final w = widget;
    if (w.streamId != old.streamId) _picked = null;
    if (w.streamId != old.streamId ||
        w.playerKey != old.playerKey ||
        w.drmAuthorization != old.drmAuthorization ||
        w.storefrontId != old.storefrontId ||
        w.offerId != old.offerId ||
        w.configId != old.configId ||
        w.sourceType != old.sourceType) {
      _stop();
      unawaited(_start());
    } else if (w.config?.features?.adCountdown !=
            old.config?.features?.adCountdown ||
        w.config?.ads?.countdownSeconds != old.config?.ads?.countdownSeconds) {
      // The ad countdown switches, or changes length, while playing; the
      // stream plays on.
      final PlayerConfig config = mergePlayerConfig(
        _remoteConfig ?? PlayerConfig.defaults,
        w.config,
      );
      setState(() {
        _config = config;
        _options = _options.withAdCountdown(
          config.features.adCountdown,
          config.adCountdownSeconds,
        );
      });
    }
  }

  /// Sets Chromecast up, or tears it down, as the widget and config allow:
  /// phones and tablets only.
  void _setUpCast(bool enabled) {
    if (!enabled || widget.isTv) {
      final cast = _cast;
      _cast = null;
      cast?.removeListener(_onCastChanged);
      cast?.dispose();
      return;
    }
    if (_cast != null) return;
    final platform = resolvePlayerPlatform(
      isTv: false,
      os: widget.debugOperatingSystemOverride,
    );
    if (platform == PlayerPlatform.android || platform == PlayerPlatform.ios) {
      _cast = EYZFlowCastController(
        backend: widget.castBackend ?? const NativeCastBackend(),
        onPlayback: _onCastPlayback,
        onEnded: _onCastEnded,
      )..addListener(_onCastChanged);
    }
  }

  /// Bumped by each [_start], so a slower earlier one gives way.
  var _startRun = 0;

  Future<void> _start() async {
    final int run = ++_startRun;
    final w = widget;
    final PlayerPlatform? platform = resolvePlayerPlatform(
      isTv: w.isTv,
      os: w.debugOperatingSystemOverride,
    );
    final http.Client client = w.httpClient ?? (_ownedClient ??= http.Client());
    final String? configId = w.configId;
    // Side by side: neither needs the other.
    final Future<PlayerConfig?> remoteConfig =
        configId == null || configId.isEmpty
        ? Future<PlayerConfig?>.value()
        : PlayerConfigClient(
            client: client,
            endpoints: w.endpoints,
          ).load(configId);
    final Future<String?> appIdLookup = (w.playerKey == null)
        ? Future<String?>.value()
        : (w.appId != null ? Future.value(w.appId) : readAppId());
    final PlayerConfig? remote = await remoteConfig;
    final String? appId = await appIdLookup;
    if (!mounted || run != _startRun) return;
    _remoteConfig = remote;
    final PlayerConfig config = mergePlayerConfig(
      remote ?? PlayerConfig.defaults,
      w.config,
    );
    _config = config;
    // The dashboard's theme, or an inline one. Without either the overlay
    // keeps its own look rather than the web player's default purple.
    _options = PlayerOptions.fromConfig(
      config,
      applyTheme: remote != null || w.config?.theme != null,
    );
    _setUpCast(w.enableCast && config.features.chromecast);
    final String? storefrontId = w.storefrontId ?? config.drm?.storefrontId;
    final coordinator = PlaybackCoordinator(
      config: PlaybackCoordinatorConfig(
        streamId: _streamId,
        isProtected: _isProtected,
        playerKey: w.playerKey,
        configId: w.configId,
        drmAuthorization: w.drmAuthorization,
        storefrontId: storefrontId,
        drmParameters: {...?config.drm?.parameters, ...w.drmParameters},
        deviceName: w.deviceName,
        platform: platform,
        app: platform != null && appId != null
            ? PlayerApp(platform: platform, id: appId)
            : null,
        analytics: w.analytics,
        // A film the end screen picked is another offer: it reports nothing.
        offerId: _isProtected && _picked == null ? w.offerId : null,
        catalogueId: _sourceType?.catalogueId,
      ),
      licenseClient: PlayerLicenseClient(
        client: client,
        endpoints: w.endpoints,
      ),
      sessionClient: PlaybackSessionClient(
        client: client,
        endpoints: w.endpoints,
      ),
      beatSender:
          w.beatSender ??
          HttpBeatSender(client: client, endpoints: w.endpoints).call,
      usageSender:
          w.usageSender ??
          HttpUsageSender(client: client, endpoints: w.endpoints).call,
      deviceIdStore: w.deviceIdStore ?? SharedPreferencesDeviceIdStore(),
      onLimitReached: (error) => widget.onLimitReached?.call(error),
      onLicenseError: (error) => widget.onLicenseError?.call(error),
      onError: (message) => widget.onError?.call(message),
    )..addListener(_onStatus);
    setState(() {
      _coordinator = coordinator;
      _source = null;
      _recorder = null;
    });
    await coordinator.start();
  }

  void _onStatus() {
    final coordinator = _coordinator;
    if (coordinator == null || !mounted) return;
    if (coordinator.status case EYZFlowPlayerReady(
      :final drmAccessHeader,
      :final planAds,
      :final adTargeting,
    )) {
      final w = widget;
      final source = EYZFlowSource(
        id: _streamId,
        title: _picked?.title ?? w.title,
        description: _picked != null ? _picked!.description : w.description,
        poster: _picked != null ? _picked!.poster : w.poster,
        drmAccessHeader: drmAccessHeader,
        sourceType: _sourceType,
        progressSeconds: _picked != null ? null : w.progressSeconds,
      );
      final store = w.watchProgressStore;
      final firstReady = _source == null;
      if (firstReady) {
        // The session has answered before the player mounts, so before the
        // pre-roll's request: a plan without ads requests none at all.
        final String? adTag = planAdTag(
          _config.adTagUrl,
          planAds: planAds,
          targeting: adTargeting,
        );
        _options = _options.withAds(
          adTag == null ? null : PlayerAds(adTagUrl: adTag),
        );
      }
      _source = source;
      if (firstReady) unawaited(_cast?.scan());
      _recorder = store != null && _isProtected
          ? WatchProgressRecorder(
              store: store,
              target: VideoplayerSourceTarget(source),
            )
          : null;
    }
    setState(() {});
  }

  void _onEvent(PlaybackEvent event) {
    _coordinator?.onPlaybackEvent(event);
    if (event is PlaybackReady) widget.onReady?.call();
    if (event is PlaybackSignalEnded) widget.onSignal?.call(null);
    if (event is PlaybackSignalStarted) widget.onSignal?.call(event.signal);
    widget.onPlaybackEvent?.call(event);
  }

  /// Whether to show the Cast button: a TV was found, and a film has the
  /// EYZFlow receiver to play its DRM.
  bool get _castAvailable {
    final cast = _cast;
    if (cast == null || cast.devices.isEmpty) return false;
    return !_isProtected || _castReceiverAppId != null;
  }

  void _onCastChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _onCastRequested(Duration position) async {
    final cast = _cast;
    final source = _source;
    if (cast == null || source == null || cast.isCasting) return;
    final target = await showCastPicker(context, cast);
    if (target == null || !mounted) return;
    // The phone stops: the player unmounts as the casting screen takes over.
    _onEvent(PlaybackPaused(sourceId: source.id, position: position));
    _castPlayerState = null;
    await cast.cast(
      target,
      castMediaFor(
        source,
        startAt: position,
        accessHeader: source.drmAccessHeader,
      ),
      appId: _castReceiverAppId ?? defaultCastReceiverAppId,
    );
  }

  /// The TV's states, as the phone player would report them: they feed the
  /// beats and the host's events, and the TV's position is watch progress.
  void _onCastPlayback(CastPlayback playback) {
    final source = _source;
    if (source == null) return;
    final previous = _castPlayerState;
    _castPlayerState = playback.state;
    _recorder?.report(playback.position);
    if (previous == playback.state) return;
    final position = playback.position;
    final duration = playback.duration;
    final String id = source.id;
    if (previous == CastPlayerState.buffering) {
      _onEvent(
        PlaybackBufferingEnded(
          sourceId: id,
          position: position,
          duration: duration,
        ),
      );
    }
    switch (playback.state) {
      case CastPlayerState.playing:
        _onEvent(
          PlaybackResumed(sourceId: id, position: position, duration: duration),
        );
      case CastPlayerState.paused:
        _onEvent(
          PlaybackPaused(sourceId: id, position: position, duration: duration),
        );
      case CastPlayerState.buffering:
        _onEvent(
          PlaybackBufferingStarted(
            sourceId: id,
            position: position,
            duration: duration,
          ),
        );
      case CastPlayerState.idle:
        break;
    }
  }

  void _onCastEnded(CastEndReason reason, Duration position) {
    final source = _source;
    if (source == null || !mounted) return;
    final target = switch (_cast?.state) {
      CastFailed(:final target) => target,
      _ => null,
    };
    if (reason == CastEndReason.finished) {
      _onEvent(PlaybackCompleted(sourceId: source.id, position: position));
      _recorder?.finish();
      _close();
      return;
    }
    if (reason == CastEndReason.failed && target != null) {
      final message = streamingL10n.castFailed(target.name);
      _onEvent(
        PlaybackError(
          sourceId: source.id,
          position: position,
          message: message,
        ),
      );
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
    }
    _recorder?.checkpoint(position);
    if (_closing) return;
    // The phone takes over where the TV was.
    setState(() {
      _source = EYZFlowSource(
        id: source.id,
        title: source.title,
        description: source.description,
        poster: source.poster,
        drmAccessHeader: source.drmAccessHeader,
        sourceType: source.sourceType,
        progressSeconds: position.inMilliseconds / 1000,
      );
      _playerGeneration += 1;
    });
  }

  Future<void> _closeWhileCasting() async {
    _closing = true;
    await _cast?.stop();
    if (mounted) _close();
  }

  void _close() {
    final handler = widget.onCloseRequested;
    if (handler != null) {
      handler();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _stop() {
    final coordinator = _coordinator;
    _coordinator = null;
    coordinator?.removeListener(_onStatus);
    coordinator?.dispose();
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) unawaited(recorder.flush());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    final cast = _cast;
    _cast = null;
    cast?.removeListener(_onCastChanged);
    cast?.dispose();
    _stop();
    // After the coordinator's final beat and session close are under way.
    final client = _ownedClient;
    if (client != null) {
      Future<void>.delayed(const Duration(seconds: 10), client.close);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = _coordinator;
    final status = coordinator?.status ?? const EYZFlowPlayerLoading();
    switch (status) {
      case EYZFlowPlayerLoading():
        return const _Loading();
      case EYZFlowPlayerFailed(:final failure):
        return widget.errorBuilder?.call(context, failure, _close) ??
            EYZFlowErrorView(
              message: failure.message,
              isTv: widget.isTv,
              onClose: _close,
            );
      case EYZFlowPlayerReady():
        final source = _source;
        if (source == null) return const _Loading();
        final cast = _cast;
        if (cast != null && cast.isCasting) {
          return CastingView(
            cast: cast,
            title: source.title,
            poster: source.poster,
            onClose: _closeWhileCasting,
          );
        }
        return PlayerOverlayScope(
          settings: EndScreenSettings.resolve(_config, widget.endScreen),
          endScreen: widget.endScreen,
          overlayBuilder: widget.overlayBuilder,
          onPick: _pick,
          child: VideoplayerFeatureView(
            key: ValueKey((coordinator, _playerGeneration)),
            videoSource: source,
            isTv: widget.isTv,
            watchProgressRecorder: _recorder,
            onCloseRequested: _close,
            onPlaybackEvent: _onEvent,
            playerBuilder: widget.playerBuilder,
            debugOperatingSystemOverride: widget.debugOperatingSystemOverride,
            castAvailable: _castAvailable,
            onCastRequested: _onCastRequested,
            options: _options,
          ),
        );
    }
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: CircularProgressIndicator(color: Colors.white)),
  );
}
