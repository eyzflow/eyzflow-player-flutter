import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ads/ad_scheduler.dart';
import '../ads/vast_ad_driver.dart';
import '../l10n/streaming_l10n.dart';
import 'player_loading_indicator.dart';
import 'player_options.dart';

/// The ads on a TV without IMA (Tizen): the ad's picture, "Ad 1 of 2 · 0:12"
/// and the Skip button, drawn by the player itself.
///
/// During an ad break it covers the content and holds the remote's focus:
/// OK on Skip skips once the ad allows it, Back leaves the player as it does
/// from the controls. Outside a break it is empty and takes nothing.
class TvAdLayer extends StatelessWidget {
  const TvAdLayer({
    super.key,
    required this.scheduler,
    required this.driver,
    required this.onBack,
    this.theme = const PlayerControlsTheme(),
  });

  final AdBreakScheduler scheduler;
  final VastAdDriver driver;
  final VoidCallback onBack;
  final PlayerControlsTheme theme;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scheduler,
    builder: (BuildContext context, _) {
      if (!scheduler.inBreak) return const SizedBox.shrink();
      return Focus(
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final LogicalKeyboardKey key = event.logicalKey;
          if (key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.escape) {
            onBack();
            return KeyEventResult.handled;
          }
          // Nothing under the ad may be reached: no seek, no panel.
          return KeyEventResult.handled;
        },
        child: ColoredBox(
          color: Colors.black,
          child: ValueListenableBuilder<AdPlaybackState?>(
            valueListenable: driver.playback,
            builder: (BuildContext context, AdPlaybackState? ad, _) {
              if (ad == null) {
                return const Center(child: PlayerLoadingIndicator(isTv: true));
              }
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ad.player.buildView(),
                  if (!ad.started)
                    const Center(child: PlayerLoadingIndicator(isTv: true)),
                  Positioned(
                    left: 32,
                    top: 24,
                    child: _AdLabel(ad: ad, theme: theme),
                  ),
                  if (ad.skipAt != null)
                    Positioned(
                      right: 32,
                      bottom: 40,
                      child: _SkipButton(
                        ad: ad,
                        theme: theme,
                        onSkip: driver.skip,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

class _AdLabel extends StatelessWidget {
  const _AdLabel({required this.ad, required this.theme});

  final AdPlaybackState ad;
  final PlayerControlsTheme theme;

  @override
  Widget build(BuildContext context) {
    final int? left = ad.secondsLeft;
    final String time = left == null
        ? ''
        : ' · ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}';
    return DecoratedBox(
      key: const ValueKey<String>('eyzflow-ad-label'),
      decoration: BoxDecoration(
        color: const Color(0xB8000000),
        borderRadius: BorderRadius.circular(theme.radius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          '${streamingL10n.adPosition(ad.index, ad.count)}$time',
          style: TextStyle(
            color: theme.textColor,
            fontSize: 20,
            fontWeight: FontWeight.w500,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _SkipButton extends StatefulWidget {
  const _SkipButton({
    required this.ad,
    required this.theme,
    required this.onSkip,
  });

  final AdPlaybackState ad;
  final PlayerControlsTheme theme;
  final VoidCallback onSkip;

  @override
  State<_SkipButton> createState() => _SkipButtonState();
}

class _SkipButtonState extends State<_SkipButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'eyzflow-ad-skip');

  @override
  void initState() {
    super.initState();
    _focusWhenSkippable();
  }

  @override
  void didUpdateWidget(_SkipButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _focusWhenSkippable();
  }

  /// The layer holds the focus while the ad plays; the moment Skip is
  /// offered it moves here, so OK skips. Requested after the frame, once the
  /// button is in the tree.
  void _focusWhenSkippable() {
    if (!widget.ad.canSkip || _focus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.ad.canSkip) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  PlayerControlsTheme get theme => widget.theme;

  @override
  Widget build(BuildContext context) {
    final int? wait = widget.ad.skipIn;
    if (wait != null) {
      return _box(
        key: const ValueKey<String>('eyzflow-ad-skip-wait'),
        focused: false,
        child: Text(
          streamingL10n.adSkipIn(wait),
          style: TextStyle(color: theme.textColor, fontSize: 20),
        ),
      );
    }
    if (!widget.ad.canSkip) return const SizedBox.shrink();
    return Focus(
      focusNode: _focus,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onSkip();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ListenableBuilder(
        listenable: _focus,
        builder: (BuildContext context, _) {
          final bool focused = _focus.hasFocus;
          final Color ink = focused ? Colors.black : theme.textColor;
          return GestureDetector(
            onTap: widget.onSkip,
            child: _box(
              key: const ValueKey<String>('eyzflow-ad-skip'),
              focused: focused,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    streamingL10n.adSkip,
                    style: TextStyle(
                      color: ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.skip_next, color: ink),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _box({
    required Key key,
    required bool focused,
    required Widget child,
  }) => DecoratedBox(
    key: key,
    decoration: BoxDecoration(
      color: focused
          ? (theme.accentColor ?? Colors.white)
          : const Color(0xB8000000),
      borderRadius: BorderRadius.circular(theme.radius),
      border: Border.all(color: theme.textColor.withValues(alpha: 0.6)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: child,
    ),
  );
}
