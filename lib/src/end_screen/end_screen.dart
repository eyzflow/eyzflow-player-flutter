import 'package:flutter/widgets.dart';

import '../core/player_config.dart';
import '../core/source.dart';
import '../signals/stream_signals.dart';

/// A film or episode the end screen offers. The app supplies them; the player
/// plays [streamId] in place when it is picked.
@immutable
final class EyzflowEndScreenItem {
  const EyzflowEndScreenItem({
    required this.streamId,
    required this.title,
    this.poster,
    this.description,
    this.duration,
    this.badge,
    this.sourceType,
    this.data,
  });

  final String streamId;
  final String title;

  /// Shown 16:9.
  final Uri? poster;
  final String? description;
  final Duration? duration;

  /// A short tag over the poster, e.g. "New" or "S1 E2".
  final String? badge;

  /// How it plays when picked. Null: the same kind as the stream playing
  /// (a film plays with DRM, its progress recorded against [streamId]).
  final EyzflowSourceType? sourceType;

  /// Anything the app wants back in [EyzflowEndScreen.onSelect].
  final Object? data;
}

/// The viewer (or the "Up next" countdown) picked an item.
final class EndScreenSelection {
  EndScreenSelection(this.item, {required this.autoplay});

  final EyzflowEndScreenItem item;

  /// Picked by the countdown reaching 0, not by the viewer.
  final bool autoplay;

  bool _prevented = false;
  bool get isPrevented => _prevented;

  /// The player does not play the item itself: the app handles it.
  void preventDefault() => _prevented = true;
}

/// The built-in end screen: "Up next" with a countdown and a row of films,
/// over the closing credits (the video shrunk into a corner) or after the
/// film. The player config's `features.endScreen` and `endScreen` settings
/// apply where this leaves them out.
@immutable
final class EyzflowEndScreen {
  const EyzflowEndScreen({
    this.items = const <EyzflowEndScreenItem>[],
    this.nextUp,
    this.autoplaySeconds,
    this.title,
    this.showAt,
    this.shrinkVideo,
    this.secondsBeforeEnd,
    this.enabled = true,
    this.onSelect,
    this.itemBuilder,
  });

  /// The row of films.
  final List<EyzflowEndScreenItem> items;

  /// The next stream: "Up next", played when its countdown reaches 0.
  final EyzflowEndScreenItem? nextUp;

  /// Seconds the countdown runs (0–30; 0: none). Null: the config's, else 10.
  final int? autoplaySeconds;

  /// The row's heading; "More like this" in the viewer's language by default.
  final String? title;
  final EndScreenShowAt? showAt;
  final bool? shrinkVideo;

  /// On a stream without a closing credits signal, the end screen shows this
  /// many seconds before the end, as at the credits (0–120; 0: only when the
  /// film ends). Null: the config's, else 20.
  final int? secondsBeforeEnd;

  /// False turns it off for this player, over the config.
  final bool enabled;

  /// Hears every pick before the player plays it in place; call
  /// [EndScreenSelection.preventDefault] to handle it yourself.
  final void Function(EndScreenSelection selection)? onSelect;

  /// Draws one film instead of the built-in card; call `select` to pick it.
  final Widget Function(
    BuildContext context,
    EyzflowEndScreenItem item,
    VoidCallback select,
  )?
  itemBuilder;
}

/// The end screen as one player shows it: the app's values over the config.
@immutable
final class EndScreenSettings {
  const EndScreenSettings({
    required this.enabled,
    required this.autoplaySeconds,
    required this.showAt,
    required this.shrinkVideo,
    this.secondsBeforeEnd = defaultEndScreenSecondsBeforeEnd,
  });

  /// On only with something to show (items or a next stream),
  /// `features.endScreen` not false and the app not switching it off.
  factory EndScreenSettings.resolve(
    PlayerConfig config,
    EyzflowEndScreen? options,
  ) {
    final PlayerEndScreenConfig? remote = config.endScreen;
    final bool hasContent =
        options != null && (options.items.isNotEmpty || options.nextUp != null);
    return EndScreenSettings(
      enabled: hasContent && config.features.endScreen && options.enabled,
      autoplaySeconds:
          endScreenAutoplayLength(options?.autoplaySeconds) ??
          remote?.autoplaySeconds ??
          defaultEndScreenAutoplaySeconds,
      showAt: options?.showAt ?? remote?.showAt ?? EndScreenShowAt.credits,
      shrinkVideo: options?.shrinkVideo ?? remote?.shrinkVideo ?? true,
      secondsBeforeEnd:
          endScreenSecondsBeforeEnd(options?.secondsBeforeEnd) ??
          remote?.secondsBeforeEnd ??
          defaultEndScreenSecondsBeforeEnd,
    );
  }

  final bool enabled;
  final int autoplaySeconds;
  final EndScreenShowAt showAt;
  final bool shrinkVideo;
  final int secondsBeforeEnd;

  @override
  bool operator ==(Object other) =>
      other is EndScreenSettings &&
      other.enabled == enabled &&
      other.autoplaySeconds == autoplaySeconds &&
      other.showAt == showAt &&
      other.shrinkVideo == shrinkVideo &&
      other.secondsBeforeEnd == secondsBeforeEnd;

  @override
  int get hashCode => Object.hash(
    enabled,
    autoplaySeconds,
    showAt,
    shrinkVideo,
    secondsBeforeEnd,
  );
}

/// When the end screen shows.
enum EndScreenPhase { credits, ended }

/// Over the closing credits (with [EndScreenShowAt.credits]); on a stream
/// without them ([hasClosingCredits] false) the last
/// [EndScreenSettings.secondsBeforeEnd] seconds count as the credits. After
/// the end (or in its last second: credits that run to the end leave their
/// signal a moment before). Or not now.
EndScreenPhase? endScreenPhase(
  EndScreenSettings settings,
  StreamSignal? signal, {
  required bool ended,
  Duration? position,
  Duration? duration,
  bool hasClosingCredits = true,
}) {
  if (!settings.enabled) return null;
  if (ended) return EndScreenPhase.ended;
  if (settings.showAt != EndScreenShowAt.credits) return null;
  if (signal?.type == StreamSignalType.closingCredits) {
    return EndScreenPhase.credits;
  }
  if (!hasClosingCredits &&
      settings.secondsBeforeEnd > 0 &&
      position != null &&
      duration != null &&
      duration > Duration.zero &&
      position >= duration - Duration(seconds: settings.secondsBeforeEnd)) {
    return EndScreenPhase.credits;
  }
  return null;
}

/// "1 h 32 min", "45 min"; empty for a missing or very short length.
String formatRuntime(Duration? duration) {
  if (duration == null || duration < const Duration(minutes: 1)) return '';
  final int minutes = (duration.inSeconds / 60).round();
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m min';
}

/// What an app's [PlayerOverlayBuilder] can do to playback.
final class PlayerOverlayControls {
  const PlayerOverlayControls({
    required this.skip,
    required this.seek,
    required this.play,
    required this.pause,
    required this.dismiss,
  });

  /// Jumps to the end of the signal playback is in.
  final VoidCallback skip;
  final void Function(Duration position) seek;
  final VoidCallback play;
  final VoidCallback pause;

  /// Hides the overlay until playback enters another signal or the film ends.
  final VoidCallback dismiss;
}

/// The moment an app's overlay is asked for.
@immutable
final class PlayerOverlayContext {
  const PlayerOverlayContext({
    required this.signal,
    required this.ended,
    required this.controls,
  });

  /// The intro, recap or credits signal playback is in; null after the end.
  final StreamSignal? signal;

  /// The film played to its end.
  final bool ended;
  final PlayerOverlayControls controls;
}

/// The app's own UI over the player at a signal or after the end; null shows
/// nothing. It wins over the end screen.
typedef PlayerOverlayBuilder =
    Widget? Function(BuildContext context, PlayerOverlayContext overlay);

/// What [EyzflowPlayer] gives the player routes for the overlay and the end
/// screen. Read with [PlayerOverlayScope.maybeOf].
final class PlayerOverlayScope extends InheritedWidget {
  const PlayerOverlayScope({
    super.key,
    required this.settings,
    required this.onPick,
    this.endScreen,
    this.overlayBuilder,
    required super.child,
  });

  final EndScreenSettings settings;
  final EyzflowEndScreen? endScreen;
  final PlayerOverlayBuilder? overlayBuilder;

  /// An end screen item was picked (and not prevented): play it in place.
  final void Function(EyzflowEndScreenItem item) onPick;

  static PlayerOverlayScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerOverlayScope>();

  @override
  bool updateShouldNotify(PlayerOverlayScope old) =>
      old.settings != settings ||
      !identical(old.endScreen, endScreen) ||
      !identical(old.overlayBuilder, overlayBuilder) ||
      old.onPick != onPick;
}
