import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';

import '../core/player_config.dart' show PlayerSkipButtonTypes;
import '../l10n/generated/eyzflow_streaming_localizations.dart';
import '../l10n/player_language.dart';
import '../signals/stream_signals.dart';
import 'player_options.dart';

/// The button's text in [language] (en, de, fr, nl; English otherwise), by
/// default the player's language: the one the host set, else the device's.
String skipSignalLabel(StreamSignalType type, {String? language}) {
  final EYZFlowStreamingLocalizations l10n =
      lookupEYZFlowStreamingLocalizations(
        Locale(eyzflowPlayerLanguageFor(language)),
      );
  return switch (type) {
    StreamSignalType.intro => l10n.skipIntro,
    StreamSignalType.recap => l10n.skipRecap,
    StreamSignalType.openingCredits => l10n.skipOpeningCredits,
    StreamSignalType.closingCredits => l10n.skipClosingCredits,
  };
}

/// How far above the bottom edge the button sits: clear of the native
/// controls' bar on phones and of the overlay's progress bar on TV.
const double skipSignalButtonBottom = 72;

/// "Skip intro", "Skip recap" or "Skip credits", bottom right, while
/// [signal] has one.
///
/// On phones and tablets it is tapped. On TV ([remote]) it is a light pill
/// with the OK key beside its label; with a [focusNode] the overlay puts focus on it while its
/// own controls are hidden, and OK skips. Without one it never takes focus
/// and the remote's OK reaches [onSkip] some other way. Colours and corners
/// come from the player config's theme, like the TV overlay's bar.
class SkipSignalButton extends StatelessWidget {
  const SkipSignalButton({
    super.key,
    required this.signal,
    required this.onSkip,
    this.theme = const PlayerControlsTheme(),
    this.remote = false,
    this.focusNode,
    this.types = const PlayerSkipButtonTypes(),
  });

  final ValueListenable<StreamSignal?> signal;
  final VoidCallback onSkip;
  final PlayerControlsTheme theme;
  final bool remote;
  final FocusNode? focusNode;

  /// Signal types without a button (by default the closing credits) show
  /// nothing.
  final PlayerSkipButtonTypes types;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<StreamSignal?>(
    valueListenable: signal,
    builder: (BuildContext context, StreamSignal? current, _) {
      if (current == null || !types.allows(current.type)) {
        return const Positioned(right: 0, bottom: 0, child: SizedBox.shrink());
      }
      final String label = skipSignalLabel(current.type);
      final Widget face = remote
          ? _remoteFace(label)
          : DecoratedBox(
              key: const ValueKey<String>('eyzflow-skip-signal'),
              decoration: BoxDecoration(
                color: theme.barColor,
                borderRadius: BorderRadius.circular(theme.radius),
                border: Border.all(
                  color: theme.textColor.withValues(alpha: 0.55),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: theme.textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            );
      return Positioned(
        right: remote ? 48 : 16,
        bottom: skipSignalButtonBottom + MediaQuery.paddingOf(context).bottom,
        child: remote
            ? _remoteButton(label, face)
            : Semantics(
                button: true,
                label: label,
                onTap: onSkip,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSkip,
                    child: face,
                  ),
                ),
              ),
      );
    },
  );

  /// On TV: a light pill, the one bright shape over the film, with the
  /// remote key that presses it. The theme's text colour is its fill and the
  /// panel colour its ink, so the pair stays readable with any config.
  Widget _remoteFace(String label) {
    final Color ink = theme.panelColor.withValues(alpha: 1);
    return DecoratedBox(
      key: const ValueKey<String>('eyzflow-skip-signal'),
      decoration: BoxDecoration(
        color: theme.textColor.withValues(alpha: theme.textColor.a * 0.94),
        borderRadius: BorderRadius.circular(theme.radius + 6),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            blurRadius: 24,
            offset: Offset(0, 8),
            color: Color(0x66000000),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 11, 16, 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                color: ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'OK',
              style: TextStyle(
                color: ink.withValues(alpha: 0.55),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _remoteButton(String label, Widget face) {
    final Widget announced = Semantics(
      container: true,
      liveRegion: true,
      button: focusNode != null,
      label: label,
      child: ExcludeSemantics(child: face),
    );
    final FocusNode? node = focusNode;
    if (node == null) return ExcludeFocus(child: announced);
    return FocusableActionDetector(
      focusNode: node,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onSkip();
            return null;
          },
        ),
      },
      child: announced,
    );
  }
}
