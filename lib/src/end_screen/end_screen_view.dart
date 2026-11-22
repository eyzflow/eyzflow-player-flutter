import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../l10n/generated/eyzflow_streaming_localizations.dart';
import '../l10n/player_language.dart';
import '../player/player_options.dart';
import '../signals/stream_signals.dart';
import 'end_screen.dart';

/// Whether the end screen takes over when the film ends, so the player stays
/// open on it instead of closing.
bool endScreenAtTheEnd(BuildContext context) {
  final PlayerOverlayScope? scope = context
      .getInheritedWidgetOfExactType<PlayerOverlayScope>();
  return scope != null && scope.endScreen != null && scope.settings.enabled;
}

/// Where playback is, for the overlay layer: fed from the player's position
/// reports.
@immutable
final class PlaybackFacts {
  const PlaybackFacts({
    this.position,
    this.duration,
    this.playing = false,
    this.ended = false,
  });

  final Duration? position;
  final Duration? duration;
  final bool playing;
  final bool ended;

  /// The film ended, or is in its last second.
  bool get atEnd {
    if (ended) return true;
    final Duration? p = position;
    final Duration? d = duration;
    return p != null &&
        d != null &&
        d > Duration.zero &&
        p >= d - const Duration(seconds: 1);
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackFacts &&
      other.position == position &&
      other.duration == duration &&
      other.playing == playing &&
      other.ended == ended;

  @override
  int get hashCode => Object.hash(position, duration, playing, ended);
}

/// What the overlay layer is doing, for the rest of the player: while it is
/// [active] the skip button stays away.
final class PlayerOverlayState extends ChangeNotifier {
  bool _active = false;
  bool _disposed = false;
  bool get active => _active;

  void _set(bool active) {
    if (_disposed || active == _active) return;
    _active = active;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The video surface with, over it, the app's overlay ([PlayerOverlayScope]'s
/// builder) or the built-in end screen. At the closing credits the end screen
/// shrinks the surface into the top-right corner by resizing it (no
/// transform, which native platform views do not always follow); a tap on it
/// goes back to the credits.
///
/// Always in the tree from the first frame, also without a scope, so the
/// surface is never re-parented.
class PlayerOverlayLayer extends StatefulWidget {
  const PlayerOverlayLayer({
    super.key,
    required this.surface,
    required this.signal,
    required this.facts,
    required this.inAdBreak,
    required this.controls,
    required this.state,
    this.theme = const PlayerControlsTheme(),
    this.remote = false,
  });

  final Widget surface;

  /// The signal playback is in, and all of the stream's signals.
  final SignalTracker signal;
  final ValueListenable<PlaybackFacts> facts;
  final bool inAdBreak;

  /// skip, seek, play and pause; `dismiss` is the layer's own.
  final PlayerOverlayControls controls;
  final PlayerOverlayState state;
  final PlayerControlsTheme theme;

  /// TV: the end screen takes the remote's focus.
  final bool remote;

  @override
  State<PlayerOverlayLayer> createState() => _PlayerOverlayLayerState();
}

class _PlayerOverlayLayerState extends State<PlayerOverlayLayer> {
  /// Dismissed moments: `signal:<id>`, `ended`, or the end screen's phase.
  final Set<String> _dismissed = <String>{};

  void _dismiss(String key) => setState(() => _dismissed.add(key));

  @override
  Widget build(BuildContext context) {
    final PlayerOverlayScope? scope = PlayerOverlayScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.signal, widget.facts]),
      builder: (BuildContext context, _) {
        final StreamSignal? signal = widget.signal.value;
        final PlaybackFacts facts = widget.facts.value;
        final bool ready = scope != null && !widget.inAdBreak;

        // The app's own overlay first.
        Widget? custom;
        String? customKey;
        if (ready && scope.overlayBuilder != null) {
          customKey = signal != null
              ? 'signal:${signal.id}'
              : (facts.ended ? 'ended' : null);
          if (customKey != null && !_dismissed.contains(customKey)) {
            final String key = customKey;
            custom = scope.overlayBuilder!(
              context,
              PlayerOverlayContext(
                signal: signal,
                ended: facts.ended,
                controls: PlayerOverlayControls(
                  skip: widget.controls.skip,
                  seek: widget.controls.seek,
                  play: widget.controls.play,
                  pause: widget.controls.pause,
                  dismiss: () => _dismiss(key),
                ),
              ),
            );
          }
        }

        // Else the end screen.
        EndScreenPhase? phase;
        if (ready && custom == null && scope.endScreen != null) {
          phase = endScreenPhase(
            scope.settings,
            signal,
            ended: facts.atEnd,
            position: facts.position,
            duration: facts.duration,
            hasClosingCredits: widget.signal.signals.any(
              (StreamSignal s) => s.type == StreamSignalType.closingCredits,
            ),
          );
          if (phase != null && _dismissed.contains('end:${phase.name}')) {
            phase = null;
          }
        }
        final bool shrunk =
            phase == EndScreenPhase.credits && scope!.settings.shrinkVideo;
        final bool active = custom != null || phase != null;
        // Not during build: the player rebuilds on it.
        scheduleMicrotask(() {
          if (mounted) widget.state._set(active);
        });

        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double width = box.maxWidth;
            final double height = box.maxHeight;
            final EdgeInsets padding = MediaQuery.paddingOf(context);
            const double scale = 0.34;
            final Rect small = Rect.fromLTWH(
              width - width * scale - 16 - padding.right,
              16 + padding.top,
              width * scale,
              height * scale,
            );
            final Rect full = Rect.fromLTWH(0, 0, width, height);
            final Rect rect = shrunk ? small : full;
            const Duration motion = Duration(milliseconds: 350);
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                AnimatedPositioned.fromRect(
                  rect: rect,
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(shrunk ? 10 : 0),
                    child: widget.surface,
                  ),
                ),
                ?custom,
                if (phase != null)
                  EndScreenView(
                    options: scope!.endScreen!,
                    settings: scope.settings,
                    phase: phase,
                    counting: facts.playing || facts.atEnd,
                    theme: widget.theme,
                    remote: widget.remote,
                    leaveRightFor: shrunk ? small.width + 32 : 0,
                    onPick: (EyzflowEndScreenItem item, bool autoplay) {
                      final EndScreenSelection selection = EndScreenSelection(
                        item,
                        autoplay: autoplay,
                      );
                      scope.endScreen!.onSelect?.call(selection);
                      if (!selection.isPrevented) scope.onPick(item);
                    },
                    onBack: () => _dismiss('end:${phase!.name}'),
                  ),
                // The small video goes back to the credits when tapped.
                if (shrunk)
                  Positioned.fromRect(
                    rect: small,
                    child: GestureDetector(
                      key: const ValueKey<String>('eyzflow-end-screen-video'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _dismiss('end:${phase!.name}'),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// "Up next" with its countdown and a row of films. Every part is focusable
/// for the TV remote; on TV the first button takes the focus.
class EndScreenView extends StatefulWidget {
  const EndScreenView({
    super.key,
    required this.options,
    required this.settings,
    required this.phase,
    required this.counting,
    required this.onPick,
    required this.onBack,
    this.theme = const PlayerControlsTheme(),
    this.remote = false,
    this.leaveRightFor = 0,
  });

  final EyzflowEndScreen options;
  final EndScreenSettings settings;
  final EndScreenPhase phase;

  /// The countdown runs only while this is true.
  final bool counting;
  final void Function(EyzflowEndScreenItem item, bool autoplay) onPick;
  final VoidCallback onBack;
  final PlayerControlsTheme theme;
  final bool remote;

  /// Width kept free on the right for the shrunk video.
  final double leaveRightFor;

  @override
  State<EndScreenView> createState() => _EndScreenViewState();
}

class _EndScreenViewState extends State<EndScreenView> {
  int? _left;
  Timer? _timer;
  bool _picked = false;

  @override
  void initState() {
    super.initState();
    final int seconds = widget.options.nextUp == null
        ? 0
        : widget.settings.autoplaySeconds;
    _left = seconds > 0 ? seconds : null;
    _sync();
  }

  @override
  void didUpdateWidget(EndScreenView old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Runs the countdown while counting, a second at a time.
  void _sync() {
    final bool run = _left != null && widget.counting && !_picked;
    if (run && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final int? left = _left;
        if (left == null || !mounted) return;
        if (left <= 1) {
          _timer?.cancel();
          _timer = null;
          setState(() => _left = 0);
          _pick(widget.options.nextUp!, autoplay: true);
        } else {
          setState(() => _left = left - 1);
        }
      });
    } else if (!run) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _pick(EyzflowEndScreenItem item, {bool autoplay = false}) {
    if (_picked) return;
    setState(() => _picked = true);
    _timer?.cancel();
    widget.onPick(item, autoplay);
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    setState(() => _left = null);
  }

  @override
  Widget build(BuildContext context) {
    final EYZFlowStreamingLocalizations l10n =
        lookupEYZFlowStreamingLocalizations(
          Locale(eyzflowPlayerLanguageFor(null)),
        );
    final PlayerControlsTheme theme = widget.theme;
    final bool tv = widget.remote;
    final double scale = tv ? 1.25 : 1;
    final EyzflowEndScreenItem? next = widget.options.nextUp;
    final List<EyzflowEndScreenItem> items = widget.options.items;
    final int total = widget.settings.autoplaySeconds;
    final TextStyle text = TextStyle(
      color: theme.textColor,
      fontSize: 13 * scale,
      decoration: TextDecoration.none,
    );

    return Positioned.fill(
      child: DecoratedBox(
        key: const ValueKey<String>('eyzflow-end-screen'),
        decoration: BoxDecoration(
          gradient: widget.phase == EndScreenPhase.credits
              ? const LinearGradient(
                  colors: <Color>[
                    Color(0xEB000000),
                    Color(0xC7000000),
                    Color(0x59000000),
                  ],
                  stops: <double>[0, 0.5, 1],
                )
              : null,
          color: widget.phase == EndScreenPhase.ended
              ? const Color(0xDB000000)
              : null,
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24 * scale,
              16,
              24 * scale + widget.leaveRightFor * 0.15,
              tv ? 88 : 72,
            ),
            // On TV the end screen is its own focus scope: the D-pad moves
            // between its buttons and films, not onto the hidden controls.
            child: FocusScope(
              autofocus: tv,
              child: FocusTraversalGroup(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (widget.phase == EndScreenPhase.credits)
                      _EndButton(
                        key: const ValueKey<String>('eyzflow-end-screen-back'),
                        theme: theme,
                        plain: true,
                        onPressed: widget.onBack,
                        child: Text(
                          l10n.endScreenBackToCredits,
                          style: text.copyWith(
                            color: theme.textColor.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    if (next != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          if (MediaQuery.sizeOf(context).width >= 600)
                            Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: _Poster(
                                item: next,
                                width: 220 * scale,
                                theme: theme,
                              ),
                            ),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  l10n.endScreenUpNext.toUpperCase(),
                                  style: text.copyWith(
                                    fontSize: 11 * scale,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                    color: theme.accentColor ?? theme.textColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  next.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.copyWith(
                                    fontSize: 20 * scale,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (next.description case final String d)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      d,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.copyWith(
                                        color: theme.textColor.withValues(
                                          alpha: 0.8,
                                        ),
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  children: <Widget>[
                                    _EndButton(
                                      key: const ValueKey<String>(
                                        'eyzflow-end-screen-play',
                                      ),
                                      theme: theme,
                                      autofocus: tv,
                                      filled: true,
                                      progress: _left == null || total <= 0
                                          ? null
                                          : (total - _left!) / total,
                                      onPressed: () => _pick(next),
                                      child: Text(
                                        _left == null
                                            ? l10n.endScreenPlay
                                            : l10n.endScreenNextIn(_left!),
                                        style: text.copyWith(
                                          fontSize: 14 * scale,
                                          fontWeight: FontWeight.w600,
                                          color: theme.onFocusColor,
                                        ),
                                      ),
                                    ),
                                    if (_left != null)
                                      _EndButton(
                                        key: const ValueKey<String>(
                                          'eyzflow-end-screen-cancel',
                                        ),
                                        theme: theme,
                                        onPressed: _cancel,
                                        child: Text(
                                          l10n.endScreenCancel,
                                          style: text.copyWith(
                                            fontSize: 14 * scale,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (items.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      Text(
                        widget.options.title ?? l10n.endScreenMoreLikeThis,
                        style: text.copyWith(
                          fontSize: 15 * scale,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: (tv ? 190 : 150) * 1.0,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (BuildContext context, int i) {
                            final EyzflowEndScreenItem item = items[i];
                            final Widget Function(
                              BuildContext,
                              EyzflowEndScreenItem,
                              VoidCallback,
                            )?
                            builder = widget.options.itemBuilder;
                            if (builder != null) {
                              return builder(context, item, () => _pick(item));
                            }
                            return _EndButton(
                              key: ValueKey<String>(
                                'eyzflow-end-screen-item-${item.streamId}',
                              ),
                              theme: theme,
                              plain: true,
                              autofocus: tv && next == null && i == 0,
                              onPressed: () => _pick(item),
                              child: SizedBox(
                                width: (tv ? 220 : 170) * 1.0,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    _Poster(
                                      item: item,
                                      width: (tv ? 220 : 170) * 1.0,
                                      theme: theme,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (formatRuntime(item.duration)
                                        case final String r when r.isNotEmpty)
                                      Text(
                                        r,
                                        style: text.copyWith(
                                          fontSize: 12 * scale,
                                          color: theme.textColor.withValues(
                                            alpha: 0.65,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 16:9 poster with an optional badge.
class _Poster extends StatelessWidget {
  const _Poster({required this.item, required this.width, required this.theme});

  final EyzflowEndScreenItem item;
  final double width;
  final PlayerControlsTheme theme;

  @override
  Widget build(BuildContext context) {
    final Uri? poster = item.poster;
    return ClipRRect(
      borderRadius: BorderRadius.circular(theme.radius),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: Color(0x22FFFFFF)),
            if (poster != null)
              Image.network(
                poster.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            if (item.badge case final String badge)
              Positioned(
                top: 6,
                left: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.accentColor ?? const Color(0xFF615FFF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A button for touch and the TV remote (OK activates). Focused, it shows the
/// theme's focus colour around it.
class _EndButton extends StatefulWidget {
  const _EndButton({
    super.key,
    required this.theme,
    required this.onPressed,
    required this.child,
    this.autofocus = false,
    this.filled = false,
    this.plain = false,
    this.progress,
  });

  final PlayerControlsTheme theme;
  final VoidCallback onPressed;
  final Widget child;
  final bool autofocus;
  final bool filled;
  final bool plain;

  /// The countdown's progress, 0…1, filled from the left.
  final double? progress;

  @override
  State<_EndButton> createState() => _EndButtonState();
}

class _EndButtonState extends State<_EndButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final PlayerControlsTheme theme = widget.theme;
    final Color accent = theme.accentColor ?? const Color(0xFF615FFF);
    final double radius = theme.radius * 0.75;
    final Widget face = widget.plain
        ? widget.child
        : ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: ColoredBox(
                    color: widget.filled ? accent : const Color(0x00000000),
                  ),
                ),
                if (widget.progress case final double p)
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: p.clamp(0, 1),
                      child: const ColoredBox(color: Color(0x33FFFFFF)),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: widget.filled
                        ? null
                        : Border.all(
                            color: theme.textColor.withValues(alpha: 0.45),
                          ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    child: widget.child,
                  ),
                ),
              ],
            ),
          );
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (bool focused) =>
          setState(() => _focused = focused),
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius + 3),
              border: Border.all(
                width: 2,
                color: _focused ? theme.focusColor : const Color(0x00000000),
              ),
            ),
            child: Padding(padding: const EdgeInsets.all(2), child: face),
          ),
        ),
      ),
    );
  }
}
