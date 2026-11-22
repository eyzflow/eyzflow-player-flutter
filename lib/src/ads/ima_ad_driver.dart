import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:interactive_media_ads/interactive_media_ads.dart';

import '../player/player_loading_indicator.dart';
import '../player/player_log.dart';
import 'ad_scheduler.dart';

/// Plays the ads [AdBreakScheduler] asks for through Google IMA
/// (`interactive_media_ads`, Android and iOS).
///
/// IMA draws the ad, its countdown, skip button and click-through in its own
/// display container, a platform view [AdLayer] stacks over the content. The
/// container exists only while an ad is requested, playing or (a VMAP on a
/// stream without markers) still scheduled; [discardAds] removes it with
/// its ads manager, and the next request builds a fresh one.
final class ImaAdDriver implements AdDriver {
  ImaAdDriver({
    required this.adTagUrl,
    required this.onPauseContent,
    required this.onResumeContent,
    required this.contentDuration,
  });

  final String adTagUrl;
  final VoidCallback onPauseContent;
  final VoidCallback onResumeContent;

  /// The content's length, for a VMAP's cue points. Null until known.
  final Duration? Function() contentDuration;

  /// Set once by the scheduler's owner, before the first request.
  late final AdBreakScheduler scheduler;

  /// Bumped by every [discardAds], so answers for a dropped request or
  /// manager are recognised and dropped too.
  var _generation = 0;
  AdDisplayContainer? _container;
  AdsLoader? _loader;
  AdsManager? _manager;
  ContentProgressProvider? _progress;
  var _requestPending = false;

  /// The display container to mount, or null when no ad is under way.
  AdDisplayContainer? get container => _container;

  @override
  void requestAds() {
    _requestPending = true;
    final AdsLoader? loader = _loader;
    if (loader != null) {
      _sendRequest(loader);
      return;
    }
    // The loader needs the container on screen: it is built once the
    // container reports it was added.
    _container ??= _newContainer(_generation);
  }

  AdDisplayContainer _newContainer(int generation) => AdDisplayContainer(
    onContainerAdded: (AdDisplayContainer container) {
      if (generation != _generation) return;
      final AdsLoader loader = AdsLoader(
        container: container,
        onAdsLoaded: (OnAdsLoadedData data) =>
            unawaited(_onLoaded(data.manager, generation)),
        onAdsLoadError: (AdsLoadErrorData data) {
          if (generation != _generation) return;
          logPlayback(
            'ads failed to load: ${data.error.type.name} ${data.error.code.name}',
            error: data.error.message,
          );
          scheduler.adsFailed();
        },
      );
      _loader = loader;
      if (_requestPending) _sendRequest(loader);
    },
  );

  void _sendRequest(AdsLoader loader) {
    _requestPending = false;
    final ContentProgressProvider progress = _progress =
        ContentProgressProvider();
    final int generation = _generation;
    unawaited(
      loader
          .requestAds(
            AdsRequest(
              adTagUrl: adTagUrl,
              contentProgressProvider: progress,
              adWillAutoPlay: true,
            ),
          )
          .catchError((Object error) {
            if (generation != _generation) return;
            logPlayback('ad request failed', error: error);
            scheduler.adsFailed();
          }),
    );
  }

  Future<void> _onLoaded(AdsManager manager, int generation) async {
    if (generation != _generation) {
      unawaited(manager.destroy());
      return;
    }
    _manager = manager;
    try {
      await manager.setAdsManagerDelegate(
        AdsManagerDelegate(
          onAdEvent: (AdEvent event) => _onAdEvent(event, generation),
          onAdErrorEvent: (AdErrorEvent event) {
            if (generation != _generation) return;
            logPlayback(
              'ad failed: ${event.error.type.name} ${event.error.code.name}',
              error: event.error.message,
            );
            scheduler.adError();
          },
        ),
      );
      await manager.init(
        settings: AdsRenderingSettings(enablePreloading: true),
      );
    } on Object catch (error) {
      if (generation != _generation) return;
      logPlayback('ads manager failed', error: error);
      scheduler.adsFailed();
      return;
    }
    if (generation != _generation) return;
    scheduler.adsLoaded(manager.adCuePoints);
  }

  void _onAdEvent(AdEvent event, int generation) {
    if (generation != _generation) return;
    if (event.type != AdEventType.adProgress) {
      logPlayback('ad event ${event.type.name}');
    }
    switch (event.type) {
      case AdEventType.contentPauseRequested:
        scheduler.contentPauseRequested();
      case AdEventType.contentResumeRequested:
        scheduler.contentResumeRequested();
      case AdEventType.allAdsCompleted:
        scheduler.allAdsCompleted();
      default:
        break;
    }
  }

  @override
  void startAds() => unawaited(_quietly(_manager?.start()));

  @override
  void discardAds() {
    _generation += 1;
    _requestPending = false;
    final AdsManager? manager = _manager;
    _manager = null;
    _loader = null;
    _container = null;
    _progress = null;
    if (manager != null) unawaited(_quietly(manager.destroy()));
  }

  @override
  void contentComplete() => unawaited(_quietly(_loader?.contentComplete()));

  @override
  void contentProgress(Duration position) {
    final Duration? duration = contentDuration();
    if (duration == null || duration <= Duration.zero) return;
    unawaited(
      _quietly(_progress?.setProgress(progress: position, duration: duration)),
    );
  }

  @override
  void pauseContent() => onPauseContent();

  @override
  void resumeContent() => onResumeContent();

  static Future<void> _quietly(Future<void>? call) async {
    try {
      await call;
    } on Object catch (error) {
      logPlayback('ads call failed', error: error);
    }
  }
}

/// The ads over the content: IMA's container while an ad is under way, on
/// black while a linear ad plays, with a spinner while the content waits for
/// one. Takes the input during an ad break, so the player's controls below it
/// cannot be reached; outside one it lets every touch through.
class AdLayer extends StatelessWidget {
  const AdLayer({super.key, required this.scheduler, required this.driver});

  final AdBreakScheduler scheduler;
  final ImaAdDriver driver;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scheduler,
    builder: (BuildContext context, _) {
      final AdDisplayContainer? container = scheduler.containerNeeded
          ? driver.container
          : null;
      final bool inBreak = scheduler.inBreak;
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Not on Android: IMA plays the ad there in a SurfaceView, drawn
          // behind the window, which an opaque Flutter layer can cover.
          if (scheduler.adPlaying &&
              defaultTargetPlatform != TargetPlatform.android)
            const ColoredBox(color: Colors.black),
          // Keyed here, on the Stack's own child: the backdrop appearing
          // before it must not rebuild the platform view, which IMA allows
          // only once per container.
          if (container != null)
            IgnorePointer(
              key: ObjectKey(container),
              ignoring: !inBreak,
              child: container,
            ),
          if (inBreak && !scheduler.adPlaying)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: PlayerLoadingIndicator()),
            ),
        ],
      );
    },
  );
}
