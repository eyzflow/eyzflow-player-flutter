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
/// On phones and tablets it is tapped. On TV ([remote]) it is drawn as the
/// focused control; with a [focusNode] the overlay puts focus on it while its
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
      final Color background = remote ? theme.focusColor : theme.barColor;
      final Color foreground = remote ? theme.onFocusColor : theme.textColor;
      final Widget face = DecoratedBox(
        key: const ValueKey<String>('eyzflow-skip-signal'),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(theme.radius),
          border: Border.all(
            color: remote ? background : foreground.withValues(alpha: 0.55),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: remote ? 24 : 18,
            vertical: remote ? 12 : 11,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: remote ? 18 : 15,
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
