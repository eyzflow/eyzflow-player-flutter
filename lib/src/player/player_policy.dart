import 'dart:async';

import 'playback_target.dart';
import 'hls_renditions.dart';
import 'player_log.dart';
import '../l10n/streaming_l10n.dart';

sealed class VideoplayerRoute {
  const VideoplayerRoute();
}

/// Tizen plays both targets through the one AVPlay adapter.
final class TizenAvplayRoute extends VideoplayerRoute {
  const TizenAvplayRoute(this.target);

  final VideoplayerTarget target;
}

/// Every other platform shows the not-implemented surface.
final class NoPlayerRoute extends VideoplayerRoute {
  const NoPlayerRoute(this.operatingSystem);

  final String? operatingSystem;
}

/// Phones and tablets on Android and iOS: a DRM-capable native player with
/// its own system controls. The native UI is
/// the better one for touch, so no overlay is drawn — see
/// [NativeTvPlayerRoute] for the D-pad case.
final class NativePlayerRoute extends VideoplayerRoute {
  const NativePlayerRoute(this.target);

  final VideoplayerTarget target;
}

/// Android TV: the same DRM-capable native player as the phone route, with
/// its touch-shaped native controls turned off and the shared controls
/// overlay on top. Android TV remotes are D-pad devices; the plugin's native
/// UI cannot be reached with one.
final class NativeTvPlayerRoute extends VideoplayerRoute {
  const NativeTvPlayerRoute(this.target);

  final VideoplayerTarget target;
}

/// Dart reports Tizen as `linux`, so both names reach the AVPlay adapter.
///
/// Verified on a retail Samsung TV: `Platform.operatingSystem` answers `linux`
/// there, which is why matching only `tizen` sent Watch to the
/// not-implemented surface on real hardware. The same trap is worked around in
/// `app_feature`'s TV detection.
// ponytail: Tizen is the only Linux target this app ships; a desktop Linux run
// would now route to a plugin it does not have. Probe the Tizen device info if
// a desktop Linux build ever becomes real.
///
/// [isTv] is the host's own form-factor answer
/// ([VideoplayerFeatureView.isTv]), not a new probe.
///
/// Only Android has a TV branch: the package has no tvOS player, so `ios`
/// must never join that branch.
VideoplayerRoute buildVideoplayerRoute({
  required String? operatingSystem,
  required VideoplayerTarget target,
  bool isTv = false,
}) {
  final String? os = operatingSystem?.toLowerCase();
  if (const <String>{'tizen', 'linux'}.contains(os)) {
    return TizenAvplayRoute(target);
  }
  if (os == 'android' && isTv) {
    return NativeTvPlayerRoute(target);
  }
  if (const <String>{'android', 'ios'}.contains(os)) {
    return NativePlayerRoute(target);
  }
  return NoPlayerRoute(operatingSystem);
}

final class VideoplaybackValue {
  const VideoplaybackValue({
    this.isCompleted = false,
    this.errorMessage,
    this.position,
    this.duration,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isPaused = false,
  });

  final bool isCompleted;
  final String? errorMessage;

  /// Where playback currently is, or `null` before the native player reports
  /// one. Carried so watch progress can be recorded without the session
  /// reaching into a plugin type.
  final Duration? position;

  /// Total length, or `null` until the native player resolves it. A resume
  /// seek waits for this: catalogue runtime is metadata and must never drive a
  /// seek.
  final Duration? duration;

  /// Whether the native player is currently advancing. Defaults to `false` so
  /// adapters that cannot report it — and test fakes that do not care — need
  /// no change.
  final bool isPlaying;

  /// Whether the native player is stalled filling its buffer.
  final bool isBuffering;

  /// Whether playback is held on purpose, by the viewer or the system. Not
  /// the same as `!isPlaying`: a player that is loading, stalled, finished or
  /// failed is not playing either, and the Android plugin passes through
  /// `loaded` between a stall and playing again. Playback events read this so
  /// that none of those is reported as a pause.
  final bool isPaused;
}

abstract interface class VideoplaybackController {
  /// The controller's current value, readable without waiting for a tick.
  VideoplaybackValue get value;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  void addListener(void Function(VideoplaybackValue) listener);
  void removeListener(void Function(VideoplaybackValue) listener);
  Future<void> dispose();
}

/// Surround layouts named in the audio panel. Mono and stereo have no suffix.
String? surroundLayout(int? channels) => switch (channels) {
  6 => '5.1',
  8 => '7.1',
  _ => null,
};

String audioTrackLabel(
  String language, {
  String? layout,
  required bool description,
}) {
  final tags = [?layout, if (description) 'AD'];
  return tags.isEmpty ? language : '$language (${tags.join(', ')})';
}

/// One audio track surfaced to the controls overlay. Package-owned so nothing
/// outside the plugin adapter depends on `video_player_avplay` types.
final class PlayerAudioTrack {
  const PlayerAudioTrack({
    required this.trackId,
    required this.language,
    this.channel,
    this.characteristics = const <String>{},
  });

  final int trackId;
  final String language;

  /// Independent audio channels: `2` stereo, `6` 5.1, `8` 7.1.
  final int? channel;

  /// "5.1"/"7.1" for surround layouts, otherwise `null`: stereo and mono
  /// need no qualifier, and other counts have no conventional name.
  String? get surroundLabel => surroundLayout(channel);

  /// The rendition's HLS `CHARACTERISTICS` UTIs (RFC 8216 §4.3.4.2.1).
  final Set<String> characteristics;

  /// `public.accessibility.describes-video`: an audio-description mix.
  bool get isAudioDescription => characteristics.contains(hlsDescribesVideo);
}

/// One text (subtitle/caption) track surfaced to the controls overlay.
final class PlayerTextTrack {
  const PlayerTextTrack({
    required this.trackId,
    required this.language,
    this.characteristics = const <String>{},
  });

  final int trackId;
  final String language;

  /// The rendition's HLS `CHARACTERISTICS` UTIs (RFC 8216 §4.3.4.2.1).
  final Set<String> characteristics;

  /// Subtitles for the deaf and hard of hearing: dialogue plus music and
  /// sound, the pair Apple's players also require before labelling SDH.
  bool get isSdh =>
      characteristics.contains(hlsTranscribesSpokenDialog) &&
      characteristics.contains(hlsDescribesMusicAndSound);
}

/// Track discovery and selection. Separate from [VideoplaybackController] so
/// playback-only fakes need not fake tracks — the Tizen adapter implements
/// both.
abstract interface class VideoplaybackTracks {
  /// Audio tracks the native player has discovered. Empty until initialized.
  Future<List<PlayerAudioTrack>> audioTracks();

  /// Text tracks the native player has discovered. Empty until initialized.
  Future<List<PlayerTextTrack>> textTracks();

  int? get selectedAudioTrackId;
  int? get selectedTextTrackId;

  Future<bool> selectAudioTrack(int trackId);

  /// A `null` id clears subtitles.
  Future<bool> selectTextTrack(int? trackId);
}

/// The source's recorded position, or `null` when there is nothing to resume.
Duration? resumePositionFor(VideoplayerTarget target) {
  final double? seconds = switch (target) {
    VideoplayerSourceTarget(:final source) => source.progressSeconds,
    VideoplayerTrailerTarget() => null,
  };
  if (seconds == null || seconds <= 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

typedef VideoplaybackControllerFactory =
    Future<VideoplaybackController> Function(VideoplayerTarget target);

final class VideoplaybackSession {
  VideoplaybackSession({
    required this.target,
    required this.createController,
    required this.onFinished,
    required this.onFailure,
    this.onProgress,
    this.onInitialized,
    this.onValue,
    this.startupTimeout = const Duration(seconds: 15),
    this.seeksToResumePosition = true,
    this.beforePlay,
  });

  final VideoplayerTarget target;
  final VideoplaybackControllerFactory createController;
  final void Function() onFinished;
  final void Function(String message) onFailure;

  /// Reports position and duration on every native tick. The session does no
  /// throttling: what to record, and how often, is the caller's policy.
  final void Function(Duration position, Duration duration)? onProgress;

  /// Called once the controller has initialized, before the resume seek and
  /// before play, with the controller's value at that moment.
  final void Function(VideoplaybackValue value)? onInitialized;

  /// Relays every native tick untouched, ahead of [onProgress], [onFinished]
  /// and [onFailure] — so whoever turns ticks into playback events has seen
  /// the tick that finishes or fails playback before the player is torn down
  /// for it. Not gated on the resume floor: that guards the saved position,
  /// and an observer wants the ticks from before the resume seek too.
  final void Function(VideoplaybackValue value)? onValue;
  final Duration startupTimeout;

  /// False when the controller already opened at [resumePositionFor] —
  /// Tizen hands it to PlusPlayer as `startPosition`, which seeks before
  /// prepare. A seek on the paused, freshly initialized player instead is what
  /// raced the licence and failed the hardware decoder there.
  final bool seeksToResumePosition;

  /// Awaited after the resume seek, just before the first play: a pre-roll
  /// ad plays here. Not part of [startupTimeout], which measures the
  /// content's own startup; whoever passes it bounds its own wait.
  final Future<void> Function()? beforePlay;
  VideoplaybackController? _controller;

  /// Progress is withheld until playback has reached its resume position.
  /// Ticks from before the resume seek report 0, and relaying them overwrote
  /// the viewer's saved position — so a failed resume came back as "start
  /// from the beginning", which then worked and hid the failure. Keyed on
  /// position rather than on the seek having run, so a seek that throws, or a
  /// Tizen `startPosition` the player could not apply, cannot arm it either:
  /// a viewer then watching from 0 overwrites nothing until they pass their
  /// old spot. Once reached it stays armed, so a later rewind is recorded.
  late Duration? _progressFloor = switch (resumePositionFor(target)) {
    final Duration resume when resume > _resumeLandingSlack =>
      resume - _resumeLandingSlack,
    _ => null,
  };
  var _progressArmed = false;

  /// An HLS seek lands on the segment boundary before its target, so arriving
  /// a few seconds short still counts as having resumed.
  static const Duration _resumeLandingSlack = Duration(seconds: 15);
  void Function(VideoplaybackValue)? _listener;
  Future<void>? _startup;
  Future<void>? _disposeFuture;
  var _isDisposed = false;

  /// Shares the resume floor between periodic ticks and lifecycle checkpoints.
  /// Once playback has reached the saved position, intentional rewinds count.
  bool canRecordPosition(Duration position) {
    if (!_progressArmed) {
      final floor = _progressFloor;
      _progressArmed = floor == null || position >= floor;
    }
    return _progressArmed;
  }

  Future<void> start() async {
    logPlayback('session.start attempted');
    final controller = await createController(target);
    if (_isDisposed) {
      await controller.dispose();
      return;
    }
    _controller = controller;
    String? reportedError;
    void listener(VideoplaybackValue value) {
      onValue?.call(value);
      final Duration? position = value.position;
      final Duration? duration = value.duration;
      if (position != null &&
          canRecordPosition(position) &&
          duration != null &&
          duration > Duration.zero) {
        onProgress?.call(position, duration);
      }
      if (value.isCompleted) onFinished();
      final String? errorMessage = value.errorMessage;
      // The native controller notifies on every position tick, so an error
      // reaches this listener repeatedly. Report and log it once.
      if (errorMessage == null || errorMessage == reportedError) {
        return;
      }
      reportedError = errorMessage;
      logPlayback('playback failed', error: errorMessage);
      onFailure(errorMessage);
    }

    _listener = listener;
    controller.addListener(listener);
    final startup = _initializeAndPlay(controller);
    _startup = startup;
    try {
      await startup.timeout(startupTimeout);
      if (beforePlay != null) await _playAfterHook(controller);
    } on TimeoutException {
      logPlayback('startup exceeded $startupTimeout');
      if (!_isDisposed) onFailure(streamingL10n.playbackTookTooLong);
    } on Object catch (error, stackTrace) {
      logPlayback('startup failed', error: error, stackTrace: stackTrace);
      // The error text rides along: on a retail TV the alert is the only place
      // a tester can read it.
      if (!_isDisposed) onFailure('Unable to load the video source: $error');
    }
  }

  Future<void> _initializeAndPlay(VideoplaybackController controller) async {
    await controller.initialize();
    logPlayback('initialized');
    if (_isDisposed) return;
    onInitialized?.call(controller.value);
    if (seeksToResumePosition) await _applyResumeSeek(controller);
    if (_isDisposed || beforePlay != null) return;
    await controller.play();
    logPlayback('play requested');
  }

  /// [beforePlay], then the first play, which still has [startupTimeout].
  Future<void> _playAfterHook(VideoplaybackController controller) async {
    if (_isDisposed) return;
    try {
      await beforePlay!();
    } on Object catch (error) {
      // An ad that fails must not keep the content from playing.
      logPlayback('before play failed', error: error);
    }
    if (_isDisposed) return;
    await controller.play().timeout(startupTimeout);
    logPlayback('play requested');
  }

  /// Seeks to the source's recorded position, if it has a usable one.
  ///
  /// A position at or past the duration is discarded: the asset would open on
  /// its own end frame. Failures are logged and ignored — starting from the
  /// beginning is better than not starting.
  Future<void> _applyResumeSeek(VideoplaybackController controller) async {
    final Duration? position = resumePositionFor(target);
    if (position == null) return;

    final Duration? duration = controller.value.duration;
    if (duration != null && duration > Duration.zero && position >= duration) {
      logPlayback('resume position $position is past the duration; ignored');
      // Playback starts from 0 on purpose, and would never reach this floor.
      _progressFloor = null;
      return;
    }

    try {
      await controller.seekTo(position);
      logPlayback('resumed at $position');
    } on Object catch (error) {
      logPlayback('resume seek failed', error: error);
    }
  }

  Future<void> dispose() {
    final disposeFuture = _disposeFuture;
    if (disposeFuture != null) return disposeFuture;

    _isDisposed = true;
    return _disposeFuture = _disposeAfterStartup();
  }

  Future<void> _disposeAfterStartup() async {
    final startup = _startup;
    if (startup != null) {
      try {
        // The native player cancels initialize's completion event during disposal.
        await startup;
      } on Object {
        // The startup path already reports initialization failures.
      }
    }

    final controller = _controller;
    final listener = _listener;
    _controller = null;
    _listener = null;
    if (controller == null) return;
    if (listener != null) controller.removeListener(listener);
    await controller.dispose();
  }
}
