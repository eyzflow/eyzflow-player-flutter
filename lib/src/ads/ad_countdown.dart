import 'dart:ui' show Locale;

import '../l10n/generated/eyzflow_streaming_localizations.dart';
import '../l10n/player_language.dart';
import 'ad_breaks.dart';

/// How long before a mid-roll the notice counts down ("Ad in 5" … "Ad in 1").
const Duration adCountdownWindow = Duration(seconds: 5);

/// The whole seconds left (5 … 1, rounded up) until the nearest of [starts]
/// ahead of [position], or null when none is within [adCountdownWindow].
///
/// The same rule as the web player's `countdownSeconds`.
int? countdownSeconds(Duration position, Iterable<Duration> starts) {
  Duration? next;
  for (final Duration start in starts) {
    if (start > position && (next == null || start < next)) next = start;
  }
  if (next == null) return null;
  final Duration left = next - position;
  if (left <= Duration.zero || left > adCountdownWindow) return null;
  final int seconds =
      (left.inMicroseconds + Duration.microsecondsPerSecond - 1) ~/
      Duration.microsecondsPerSecond;
  return seconds < 1 ? 1 : seconds;
}

/// The seconds to show on the notice right now, or null for none.
///
/// The notice shows only when it is switched on ([enabled]), the content is
/// playing (not paused, buffering, seeking or scrubbing: [playing]), no ad
/// break is under way ([inBreak]) and the video is not on another screen
/// ([remote]: AirPlay).
int? adCountdownFor({
  required bool enabled,
  required bool playing,
  required bool inBreak,
  required bool remote,
  required Duration? position,
  required Iterable<Duration> starts,
}) {
  if (!enabled || !playing || inBreak || remote || position == null) {
    return null;
  }
  return countdownSeconds(position, starts);
}

/// The mid-roll cue points of a VMAP tag, on streams without ad break
/// markers, where IMA plays the breaks itself. Start 0 (the pre-roll) and a
/// negative start (the post-roll) are dropped.
///
/// A cue point counts as passed once playback runs through it, so its notice
/// does not come back after a rewind: IMA plays each break once. One seeked
/// over is not passed.
final class CuePointSchedule {
  var _starts = const <Duration>[];
  final Set<Duration> _passed = <Duration>{};

  void set(Iterable<Duration> cuePoints) {
    _starts = List<Duration>.unmodifiable(
      cuePoints.where((Duration c) => c > prerollWindow).toList()..sort(),
    );
  }

  void clear() {
    _starts = const <Duration>[];
    _passed.clear();
  }

  /// Playback moved from [previous] to [current].
  void pass(Duration previous, Duration current) {
    final Duration step = current - previous;
    if (step <= Duration.zero || step > maxPlayStep) return;
    for (final Duration start in _starts) {
      if (start > previous && start <= current) _passed.add(start);
    }
  }

  List<Duration> get upcoming => <Duration>[
    for (final Duration start in _starts)
      if (!_passed.contains(start)) start,
  ];
}

/// The notice in [language] (en, de, fr, nl; English otherwise), by default
/// the player's language: the one the host set, else the device's.
String adCountdownLabel(int seconds, {String? language}) =>
    lookupEYZFlowStreamingLocalizations(
      Locale(eyzflowPlayerLanguageFor(language)),
    ).adCountdown(seconds);
