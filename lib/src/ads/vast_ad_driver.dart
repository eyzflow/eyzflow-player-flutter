import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../player/player_log.dart';
import 'ad_breaks.dart' show maxPlayStep;
import 'ad_scheduler.dart';
import 'vast.dart';
import 'vast_loader.dart';

/// What an ad's own player reports.
@immutable
final class AdMediaValue {
  const AdMediaValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isCompleted = false,
    this.position = Duration.zero,
    this.duration,
    this.errorMessage,
  });

  final bool isInitialized;
  final bool isPlaying;
  final bool isCompleted;
  final Duration position;
  final Duration? duration;
  final String? errorMessage;
}

/// The player for one ad's media file. Made, played and disposed once.
abstract interface class AdMediaPlayer {
  AdMediaValue get value;
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> dispose();
  void addListener(VoidCallback listener);
  void removeListener(VoidCallback listener);

  /// The ad's picture.
  Widget buildView();
}

typedef AdMediaPlayerFactory = AdMediaPlayer Function(VastMediaFile media);

/// The ad on screen, for the ad layer.
@immutable
final class AdPlaybackState {
  const AdPlaybackState({
    required this.index,
    required this.count,
    required this.player,
    this.position = Duration.zero,
    this.duration,
    this.skipAt,
    this.started = false,
  });

  /// 1-based.
  final int index;
  final int count;
  final AdMediaPlayer player;
  final Duration position;
  final Duration? duration;

  /// When the ad may be skipped; null when it cannot be.
  final Duration? skipAt;

  /// The first frame is up.
  final bool started;

  bool get canSkip {
    final Duration? at = skipAt;
    return started && at != null && position >= at;
  }

  /// Whole seconds until Skip is offered, or null when it is offered already
  /// or never.
  int? get skipIn {
    final Duration? at = skipAt;
    if (at == null || canSkip) return null;
    final Duration left = at - position;
    return (left.inMilliseconds / 1000).ceil().clamp(1, 1 << 30);
  }

  /// Whole seconds left in the ad, or null while its length is unknown.
  int? get secondsLeft {
    final Duration? total = duration;
    if (total == null || total <= Duration.zero) return null;
    final Duration left = total - position;
    return left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
  }

  AdPlaybackState copyWith({
    Duration? position,
    Duration? duration,
    bool? started,
  }) => AdPlaybackState(
    index: index,
    count: count,
    player: player,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    skipAt: skipAt,
    started: started ?? this.started,
  );
}

/// A VMAP break and what it resolved to.
final class _Break {
  _Break(this.source, this.at);

  final VmapBreak source;

  /// Where it plays in the content: zero for the pre-roll, negative for the
  /// post-roll (the scheduler's cue point convention, IMA's too).
  final Duration at;
  Future<List<PlayableAd>>? ads;
  var played = false;

  bool get isPreroll => at == Duration.zero;
  bool get isPostroll => at.isNegative;
}

enum _AdEnd { completed, skipped, failed, discarded }

/// Plays VAST and VMAP ads in Dart for [AdBreakScheduler], where there is no
/// IMA (Tizen). The same contract as the IMA driver: it answers the
/// scheduler's requests with `adsLoaded` / `adsFailed`, and frames each break
/// it plays with `contentPauseRequested` and `contentResumeRequested`.
///
/// * A VAST tag gives one break: its ad pod, or its first playable ad.
/// * A VMAP tag gives its breaks as cue points. The pre-roll plays on
///   [startAds]; a mid-roll when the content plays through its cue point
///   (its ads are fetched [prefetch] ahead); the post-roll on
///   [contentComplete]. Each plays once; one seeked past does not play.
/// * Each ad is its own [AdMediaPlayer]. The content is paused (and, on a
///   TV, lets go of its video decoder) before an ad player is created, so
///   the two never need a decoder at the same time.
/// * An ad that does not start within [startTimeout], stalls for
///   [stallTimeout] or fails is reported to its error URLs and the next one
///   plays; a break with nothing playable ends without an error.
final class VastAdDriver implements AdDriver {
  VastAdDriver({
    required this.adTagUrl,
    required this.loader,
    required this.createPlayer,
    required this.ping,
    required this.onPauseContent,
    required this.onResumeContent,
    required this.contentDuration,
    this.onReleaseContent,
    this.prefetch = const Duration(seconds: 8),
    this.startTimeout = const Duration(seconds: 10),
    this.stallTimeout = const Duration(seconds: 10),
  });

  final String adTagUrl;
  final VastLoader loader;
  final AdMediaPlayerFactory createPlayer;
  final AdPing ping;
  final VoidCallback onPauseContent;
  final VoidCallback onResumeContent;

  /// The content ended and a post-roll is about to play: let go of the video
  /// decoder without resuming afterwards.
  final VoidCallback? onReleaseContent;

  /// The content's length, for a VMAP's percentage offsets.
  final Duration? Function() contentDuration;
  final Duration prefetch;
  final Duration startTimeout;
  final Duration stallTimeout;

  /// Set once by the scheduler's owner, before the first request.
  late final AdBreakScheduler scheduler;

  final ValueNotifier<AdPlaybackState?> _playback =
      ValueNotifier<AdPlaybackState?>(null);

  /// The ad on screen, or null between ads and outside a break.
  ValueListenable<AdPlaybackState?> get playback => _playback;

  /// Bumped by every [discardAds]: work for a dropped request or break sees
  /// it changed and stops.
  var _generation = 0;

  /// A VAST tag's ads, waiting for [startAds].
  List<PlayableAd>? _vastAds;

  /// A VMAP tag's breaks, earliest first, the post-roll last.
  List<_Break> _breaks = const <_Break>[];
  var _playing = false;
  Duration? _lastPosition;
  Completer<_AdEnd>? _adEnd;

  @override
  void requestAds() => unawaited(_load(_generation));

  Future<void> _load(int generation) async {
    final Uri? tag = Uri.tryParse(adTagUrl);
    if (tag == null) {
      scheduler.adsFailed();
      return;
    }
    try {
      final AdTagResponse response = await loader.fetchTag(tag);
      if (generation != _generation) return;
      switch (response) {
        case VastTagResponse(:final vast):
          final List<PlayableAd> ads = await loader.resolve(vast);
          if (generation != _generation) return;
          if (ads.isEmpty) {
            logPlayback('ad tag returned no ad');
            scheduler.adsFailed();
            return;
          }
          _vastAds = ads;
          scheduler.adsLoaded(const <Duration>[]);
        case VmapTagResponse(breaks: final List<VmapBreak> breaks):
          _breaks = _schedule(breaks);
          if (_breaks.isEmpty) {
            logPlayback('VMAP has no break the player can place');
            scheduler.adsFailed();
            return;
          }
          scheduler.adsLoaded(<Duration>[for (final _Break b in _breaks) b.at]);
      }
    } on Object catch (error) {
      if (generation != _generation) return;
      logPlayback('ad tag failed', error: error);
      scheduler.adsFailed();
    }
  }

  List<_Break> _schedule(List<VmapBreak> breaks) {
    final Duration? total = contentDuration();
    final Map<Duration, _Break> byTime = <Duration, _Break>{};
    for (final VmapBreak b in breaks) {
      final Duration? at = switch (b.offset) {
        VmapStart() => Duration.zero,
        VmapEnd() => const Duration(seconds: -1),
        VmapTime(:final time) => time,
        VmapPercent(:final percent) => VastPercentOffset(
          percent,
        ).resolve(total),
      };
      if (at == null) {
        logPlayback(
          'VMAP break at ${b.offset} dropped: content length unknown',
        );
        continue;
      }
      // Two breaks at one place play as one: the first listed.
      byTime.putIfAbsent(at, () => _Break(b, at));
    }
    return byTime.values.toList()..sort((_Break a, _Break b) {
      if (a.isPostroll != b.isPostroll) return a.isPostroll ? 1 : -1;
      return a.at.compareTo(b.at);
    });
  }

  Future<List<PlayableAd>> _adsOf(_Break b) => b.ads ??= () async {
    final VastResponse? inline = b.source.inlineVast;
    final VastResponse vast;
    if (inline != null) {
      vast = inline;
    } else {
      try {
        final AdTagResponse response = await loader.fetchTag(
          b.source.adTagUri!,
        );
        if (response is! VastTagResponse) return const <PlayableAd>[];
        vast = response.vast;
      } on Object catch (error) {
        logPlayback('VMAP break ad tag failed', error: error);
        return const <PlayableAd>[];
      }
    }
    return loader.resolve(vast);
  }();

  @override
  void startAds() {
    final int generation = _generation;
    final List<PlayableAd>? vast = _vastAds;
    if (vast != null) {
      _vastAds = null;
      unawaited(_playBreak(vast, generation: generation, last: true));
      return;
    }
    for (final _Break b in _breaks) {
      if (b.isPreroll && !b.played) {
        unawaited(_playVmapBreak(b, generation));
        return;
      }
    }
  }

  @override
  void contentProgress(Duration position) {
    final Duration? previous = _lastPosition;
    _lastPosition = position;
    if (_breaks.isEmpty || _playing) return;
    final int generation = _generation;
    for (final _Break b in _breaks) {
      if (b.played || b.isPreroll || b.isPostroll) continue;
      if (position >= b.at - prefetch && position < b.at) {
        unawaited(_adsOf(b));
      }
      if (previous == null) continue;
      final Duration step = position - previous;
      final bool playedThrough =
          previous < b.at &&
          position >= b.at &&
          step > Duration.zero &&
          step <= maxPlayStep;
      if (playedThrough) {
        unawaited(_playVmapBreak(b, generation));
        return;
      }
      // Seeked past: VAST players skip it, as the web player does.
      if (position >= b.at && previous < b.at) b.played = true;
    }
  }

  @override
  void contentComplete() {
    final int generation = _generation;
    for (final _Break b in _breaks) {
      if (b.isPostroll && !b.played) {
        unawaited(_playVmapBreak(b, generation));
        return;
      }
    }
    scheduler.allAdsCompleted();
  }

  Future<void> _playVmapBreak(_Break b, int generation) async {
    b.played = true;
    _playing = true;
    final List<PlayableAd> ads = await _adsOf(b);
    if (generation != _generation) return;
    final bool last = _breaks.every((_Break other) => other.played);
    await _playBreak(
      ads,
      generation: generation,
      last: last,
      postroll: b.isPostroll,
    );
  }

  /// Plays [ads] in order as one break.
  Future<void> _playBreak(
    List<PlayableAd> ads, {
    required int generation,
    required bool last,
    bool postroll = false,
  }) async {
    _playing = true;
    try {
      if (ads.isEmpty) {
        if (scheduler.inBreak) {
          scheduler.adError();
        } else if (postroll || last) {
          scheduler.allAdsCompleted();
        }
        return;
      }
      if (postroll) onReleaseContent?.call();
      // Before the first ad player exists: the content stops (a mid-roll)
      // and lets go of the decoder the ad needs.
      scheduler.contentPauseRequested();
      for (var i = 0; i < ads.length; i++) {
        final _AdEnd end = await _playAd(
          ads[i],
          index: i + 1,
          count: ads.length,
          generation: generation,
        );
        if (end == _AdEnd.discarded || generation != _generation) return;
      }
      scheduler.contentResumeRequested();
      if (last && generation == _generation) scheduler.allAdsCompleted();
    } finally {
      if (generation == _generation) _playing = false;
    }
  }

  Future<_AdEnd> _playAd(
    PlayableAd ad, {
    required int index,
    required int count,
    required int generation,
  }) async {
    final VastAdTracker tracker = VastAdTracker(ad: ad, ping: ping);
    final AdMediaPlayer player;
    try {
      player = createPlayer(ad.media);
    } on Object catch (error) {
      logPlayback('ad player could not be created', error: error);
      tracker.failed(VastErrorCode.mediaFailed);
      return _AdEnd.failed;
    }
    final Completer<_AdEnd> end = _adEnd = Completer<_AdEnd>();
    void finish(_AdEnd how) {
      if (!end.isCompleted) end.complete(how);
    }

    final Duration? skipAt = ad.skipOffset?.resolve(ad.duration);
    if (_disposed || generation != _generation) {
      unawaited(_quietly(player.dispose()));
      return _AdEnd.discarded;
    }
    _playback.value = AdPlaybackState(
      index: index,
      count: count,
      player: player,
      duration: ad.duration,
      skipAt: skipAt,
    );
    // Whole seconds since the position last moved, counted by the watchdog.
    var stillFor = 0;
    var lastPosition = Duration.zero;
    var started = false;
    void listener() {
      if (generation != _generation) return;
      final AdMediaValue v = player.value;
      if (v.errorMessage != null) {
        logPlayback('ad playback failed', error: v.errorMessage);
        tracker.failed(VastErrorCode.mediaFailed);
        finish(_AdEnd.failed);
        return;
      }
      if (v.isCompleted) {
        finish(_AdEnd.completed);
        return;
      }
      if (v.position != lastPosition) {
        lastPosition = v.position;
        stillFor = 0;
      }
      if (!started && v.isPlaying && v.position > Duration.zero) {
        started = true;
        tracker.started();
      }
      tracker.progress(v.position, v.duration ?? ad.duration);
      final AdPlaybackState? state = _disposed ? null : _playback.value;
      if (state != null && identical(state.player, player)) {
        _playback.value = state.copyWith(
          position: v.position,
          duration: v.duration ?? ad.duration,
          started: started,
        );
      }
    }

    Timer? watchdog;
    try {
      player.addListener(listener);
      try {
        await player.initialize().timeout(startTimeout);
        if (generation != _generation) return _AdEnd.discarded;
        await player.play();
      } on TimeoutException {
        tracker.failed(VastErrorCode.mediaTimeout);
        return _AdEnd.failed;
      } on Object catch (error) {
        logPlayback('ad media failed to load', error: error);
        tracker.failed(VastErrorCode.mediaFailed);
        return _AdEnd.failed;
      }
      stillFor = 0;
      watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        stillFor += 1;
        if (Duration(seconds: stillFor) < stallTimeout) return;
        logPlayback('ad stalled');
        tracker.failed(
          started ? VastErrorCode.mediaFailed : VastErrorCode.mediaTimeout,
        );
        finish(_AdEnd.failed);
      });
      final _AdEnd how = await end.future;
      switch (how) {
        case _AdEnd.completed:
          tracker.completed();
        case _AdEnd.skipped:
          tracker.skipped();
        case _AdEnd.failed || _AdEnd.discarded:
          break;
      }
      return how;
    } finally {
      watchdog?.cancel();
      player.removeListener(listener);
      if (identical(_adEnd, end)) _adEnd = null;
      if (!_disposed && identical(_playback.value?.player, player)) {
        _playback.value = null;
      }
      unawaited(_quietly(player.dispose()));
    }
  }

  /// The viewer pressed Skip. Ignored until the ad may be skipped.
  void skip() {
    if (_disposed) return;
    final AdPlaybackState? state = _playback.value;
    final Completer<_AdEnd>? end = _adEnd;
    if (state == null || end == null || end.isCompleted || !state.canSkip) {
      return;
    }
    end.complete(_AdEnd.skipped);
  }

  @override
  void discardAds() {
    _generation += 1;
    _vastAds = null;
    _breaks = const <_Break>[];
    _playing = false;
    _lastPosition = null;
    final Completer<_AdEnd>? end = _adEnd;
    _adEnd = null;
    if (end != null && !end.isCompleted) end.complete(_AdEnd.discarded);
  }

  @override
  void pauseContent() => onPauseContent();

  @override
  void resumeContent() => onResumeContent();

  var _disposed = false;

  /// Ends any ad on screen and frees the notifier.
  void dispose() {
    if (_disposed) return;
    discardAds();
    _disposed = true;
    _playback.dispose();
  }

  static Future<void> _quietly(Future<void> call) async {
    try {
      await call;
    } on Object catch (error) {
      logPlayback('ad player call failed', error: error);
    }
  }
}
