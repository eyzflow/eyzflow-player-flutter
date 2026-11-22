import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ad_breaks.dart';
import 'ad_countdown.dart';

/// Ads for one impression: the config's ad tag, and what has been played.
///
/// [EyzflowPlayer] makes one each time playback starts and passes it to the
/// player through [PlayerOptions.ads]. It outlives the player widget, so when
/// casting hands playback back to the phone (a fresh player), the pre-roll and
/// the breaks already played do not play again.
///
/// Only made when the config's `features.ads` is on and `ads.adTagUrl` is set;
/// without it no ad request is made at all.
final class PlayerAds {
  PlayerAds({required this.adTagUrl});

  /// The VAST or VMAP tag. Requested from the ad server through Google IMA.
  final String adTagUrl;

  /// The stream's ad break markers, as read from its manifest.
  final AdBreakSchedule schedule = AdBreakSchedule();

  Future<void>? _markers;
  var _prerollTaken = false;

  /// Reads the markers once per impression, with [load].
  Future<void> loadMarkers(Future<List<AdBreak>> Function() load) =>
      _markers ??= () async {
        schedule.addAll(await load());
      }();
}

/// What [AdBreakScheduler] asks of the ad SDK and the content player.
abstract interface class AdDriver {
  /// Requests [PlayerAds.adTagUrl]. The answer comes back through
  /// [AdBreakScheduler.adsLoaded] or [AdBreakScheduler.adsFailed].
  void requestAds();

  /// Starts the loaded ads: a VAST ad, or a VMAP's pre-roll.
  void startAds();

  /// Drops the ads manager and its display container. Whatever it still
  /// had scheduled never plays.
  void discardAds();

  /// The content played to its end: a VMAP's post-roll may play now.
  void contentComplete();

  /// Where the content is, for a VMAP's own mid-rolls.
  void contentProgress(Duration position);

  void pauseContent();
  void resumeContent();
}

enum _Mode {
  /// The stream has ad break markers: ads play only at them.
  markers,

  /// No markers: the tag decides (a VAST pre-roll, or a VMAP schedule).
  tag,
}

/// When ads play: the same rules as the web player.
///
/// * A stream without ad break markers requests the tag once, before the
///   content starts, and lets it decide: a VAST pre-roll, or a VMAP's own
///   schedule (pre-roll, mid-rolls at its cue points, post-roll).
/// * A stream with markers plays ads only at them. A marker at the start is a
///   pre-roll; every other marker is a mid-roll, requested from the tag when
///   playback reaches it, each played once. Markers passed by seeking are
///   not played. After each break the ads manager is dropped, so a VMAP's
///   own mid-rolls and post-roll never play: at a marker only a VMAP's
///   pre-roll plays, and one without a pre-roll gives no ad there.
/// * The content waits at a break until the ad starts, or until it turns out
///   there is none (an empty, failed or blocked tag, or no answer within
///   [guard]): then it plays on, with no error.
///
/// Pure Dart: [AdDriver] does the SDK and player work.
final class AdBreakScheduler extends ChangeNotifier {
  AdBreakScheduler({
    required this.ads,
    required this.driver,
    this.guard = const Duration(seconds: 12),
    this.onBreakStarted,
    this.onBreakEnded,
    bool Function()? suppressed,
  }) : _suppressed = suppressed ?? _never;

  final PlayerAds ads;
  final AdDriver driver;

  /// How long the content waits for an ad to start before it plays on. IMA
  /// gives up on a VAST that does not answer and reports it; this only
  /// guards against it never answering.
  final Duration guard;

  /// An ad break began: the content stopped for it. For analytics.
  final VoidCallback? onBreakStarted;

  /// The ad break is over (played, empty, failed or timed out).
  final VoidCallback? onBreakEnded;

  /// True while no ads may start, e.g. while the video plays on AirPlay.
  final bool Function() _suppressed;

  static bool _never() => false;

  _Mode _mode = _Mode.tag;
  var _disposed = false;
  var _requesting = false;
  var _managerAlive = false;
  var _inBreak = false;
  var _adPlaying = false;
  var _pausedContent = false;
  var _cuePoints = const <Duration>[];

  /// A VMAP's mid-rolls still to come, on a stream without markers.
  final CuePointSchedule _vmapMidrolls = CuePointSchedule();
  Timer? _guardTimer;
  Completer<void>? _hold;
  Duration? _lastPosition;

  /// The content played to its end: a post-roll neither pauses nor resumes
  /// it.
  var _contentEnded = false;

  /// The ads SDK needs its display container on screen: an ad is requested,
  /// playing, or (VMAP without markers) still scheduled.
  bool get containerNeeded => _requesting || _managerAlive;

  /// The content is held for an ad break: the player's controls are hidden
  /// and the ad layer takes the input.
  bool get inBreak => _inBreak;

  /// A linear ad is on screen.
  bool get adPlaying => _adPlaying;

  /// Where the mid-rolls still to come start, for the countdown before them:
  /// the stream's markers not played yet (one passed by seeking still plays
  /// later), else a loaded VMAP's mid-roll cue points not played through.
  List<Duration> get upcomingMidrolls {
    if (_disposed) return const <Duration>[];
    if (ads.schedule.hasBreaks) return ads.schedule.upcomingStarts;
    if (_mode == _Mode.tag && _managerAlive) return _vmapMidrolls.upcoming;
    return const <Duration>[];
  }

  /// Awaited before the content first plays: a pre-roll, if there is one,
  /// plays first. Completes when it is over, or at once when there is none.
  Future<void> beforeContent() async {
    if (_disposed || ads._prerollTaken) return;
    await ads._markers;
    if (_disposed || ads._prerollTaken) return;
    ads._prerollTaken = true;
    if (_suppressed()) return;
    if (ads.schedule.hasBreaks) {
      _mode = _Mode.markers;
      if (ads.schedule.takePreroll() == null) return;
    } else {
      _mode = _Mode.tag;
    }
    final Completer<void> hold = _hold = Completer<void>();
    _beginBreak();
    _request();
    await hold.future;
  }

  /// A position report from the content player.
  void contentPosition(Duration position) {
    final Duration? previous = _lastPosition;
    _lastPosition = position;
    if (_disposed) return;
    if (previous != null) _vmapMidrolls.pass(previous, position);
    if (_mode == _Mode.tag && _managerAlive) driver.contentProgress(position);
    if (previous == null ||
        !ads.schedule.hasBreaks ||
        _inBreak ||
        _requesting ||
        _suppressed()) {
      return;
    }
    if (ads.schedule.due(previous, position) == null) return;
    _mode = _Mode.markers;
    _beginBreak();
    _pausedContent = true;
    driver.pauseContent();
    _request();
  }

  /// The content played to its end. Completes once a VMAP's post-roll is
  /// over, or at once when there is none.
  Future<void> contentCompleted() async {
    if (_disposed ||
        _mode != _Mode.tag ||
        !_managerAlive ||
        _inBreak ||
        _suppressed() ||
        !_cuePoints.any((Duration c) => c.isNegative)) {
      return;
    }
    _contentEnded = true;
    final Completer<void> hold = _hold = Completer<void>();
    _startGuard();
    driver.contentComplete();
    await hold.future;
  }

  /// IMA loaded the tag. [cuePoints] are a VMAP's break positions (zero is
  /// its pre-roll, a negative one its post-roll); a VAST has none.
  void adsLoaded(List<Duration> cuePoints) {
    if (_disposed) return;
    _requesting = false;
    _managerAlive = true;
    if (!_inBreak) {
      // The break already gave up waiting for it.
      _discard();
      notifyListeners();
      return;
    }
    _cuePoints = List<Duration>.unmodifiable(cuePoints);
    if (_mode == _Mode.tag) _vmapMidrolls.set(cuePoints);
    final bool hasPreroll =
        cuePoints.isEmpty || cuePoints.contains(Duration.zero);
    if (_mode == _Mode.markers && !hasPreroll) {
      // A VMAP with no pre-roll: nothing for this marker.
      _breakOver();
      return;
    }
    driver.startAds();
    if (!hasPreroll) {
      // A VMAP without a pre-roll: the content starts, and IMA asks for it
      // to pause at its own cue points.
      _breakOver();
      return;
    }
    notifyListeners();
  }

  /// The tag could not be loaded: empty, blocked, failed or timed out.
  void adsFailed() {
    if (_disposed) return;
    _requesting = false;
    if (_inBreak || _hold != null) {
      _breakOver(drop: true);
    } else {
      _discard();
      notifyListeners();
    }
  }

  /// IMA starts an ad break: the content must pause.
  void contentPauseRequested() {
    if (_disposed) return;
    _cancelGuard();
    if (!_inBreak) {
      // A VMAP's own mid-roll or post-roll, on a stream without markers.
      _beginBreak();
      if (!_contentEnded) {
        _pausedContent = true;
        driver.pauseContent();
      }
    }
    _adPlaying = true;
    notifyListeners();
  }

  /// IMA's ad break is over: the content plays on.
  void contentResumeRequested() {
    if (_disposed || !_inBreak) return;
    _breakOver();
  }

  /// Every ad the tag scheduled has played.
  void allAdsCompleted() {
    if (_disposed) return;
    _breakOver(drop: true);
  }

  /// An ad failed while loading or playing. Outside a break IMA carries on
  /// with the rest of its schedule.
  void adError() {
    if (_disposed || !_inBreak) return;
    _breakOver();
  }

  void _request() {
    _requesting = true;
    _startGuard();
    // The driver first: it creates the display container the listeners
    // then put on screen.
    driver.requestAds();
    notifyListeners();
  }

  void _beginBreak() {
    _inBreak = true;
    onBreakStarted?.call();
  }

  void _startGuard() {
    _cancelGuard();
    _guardTimer = Timer(guard, () {
      if (!_disposed) _breakOver(drop: true);
    });
  }

  void _cancelGuard() {
    _guardTimer?.cancel();
    _guardTimer = null;
  }

  /// Ends the current break, if any, and drops the ads manager unless a
  /// VMAP on a stream without markers still has breaks to come.
  void _breakOver({bool drop = false}) {
    _cancelGuard();
    final bool wasInBreak = _inBreak;
    _inBreak = false;
    _adPlaying = false;
    final bool keep =
        !drop &&
        _mode == _Mode.tag &&
        _managerAlive &&
        _cuePoints.any((Duration c) => c != Duration.zero);
    if (!keep) _discard();
    if (wasInBreak) onBreakEnded?.call();
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null && !hold.isCompleted) hold.complete();
    if (_pausedContent) {
      _pausedContent = false;
      driver.resumeContent();
    }
    notifyListeners();
  }

  /// Also when no manager is loaded yet: a request may be out, and the
  /// driver drops its late answer.
  void _discard() {
    _requesting = false;
    _managerAlive = false;
    _cuePoints = const <Duration>[];
    _vmapMidrolls.clear();
    driver.discardAds();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelGuard();
    if (_inBreak) onBreakEnded?.call();
    _inBreak = false;
    final Completer<void>? hold = _hold;
    _hold = null;
    if (hold != null && !hold.isCompleted) hold.complete();
    driver.discardAds();
    super.dispose();
  }
}
