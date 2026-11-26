import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_options.dart';

/// One row of a [TrackPanel].
typedef TrackPanelRow = ({
  String label,
  bool selected,
  VoidCallback onSelected,
});

/// The audio or subtitle sidebar: a title and one row per track, the playing
/// one checked. Shared by the player's overlay and the casting screen, so both
/// look and behave alike.
class TrackPanel extends StatelessWidget {
  const TrackPanel({
    super.key,
    required this.theme,
    required this.title,
    required this.rows,
    this.selectedRow = 0,
  });

  final PlayerControlsTheme theme;
  final String title;
  final List<TrackPanelRow> rows;

  /// The row focused when the panel opens.
  final int selectedRow;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      // A scope, not just a traversal group. Two things follow from it, both
      // of which the group alone did not give:
      //
      // Directional traversal searches the focused node's nearest scope, so
      // the arrows are bounded to these rows — without it an arrow walked
      // straight out onto the transport still sitting underneath the panel.
      //
      // And `autofocus` is applied only to a scope with no focused child.
      // The route's scope already had one — the button that opened the panel
      // — so the checked row's autofocus was silently dropped and focus
      // stayed outside the sidebar entirely.
      child: FocusScope(
        child: FocusTraversalGroup(
          // A card floating over the film's right side, not a sidebar.
          child: Container(
            width: 260,
            margin: const EdgeInsets.fromLTRB(0, 24, 32, 24),
            decoration: BoxDecoration(
              color: theme.panelColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: theme.textColor.withValues(
                  alpha: theme.textColor.a * 0.1,
                ),
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  blurRadius: 40,
                  offset: Offset(0, 12),
                  color: Color(0x99000000),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    title.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: theme.textColor.withValues(
                        alpha: theme.textColor.a * 0.7,
                      ),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final (int index, TrackPanelRow row) in rows.indexed)
                    _TrackRow(
                      theme: theme,
                      label: row.label,
                      selected: row.selected,
                      onSelected: row.onSelected,
                      autofocus: index == selectedRow,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.theme,
    required this.label,
    required this.selected,
    required this.onSelected,
    required this.autofocus,
  });

  final PlayerControlsTheme theme;
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: autofocus,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onSelected();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (context) {
          final bool focused = Focus.of(context).hasFocus;
          final Color text = theme.textColor;
          final Color accent = theme.focusColor;
          // Focused: filled with the accent. Playing: outlined in it, so the
          // viewer sees both where they are and what is on.
          return GestureDetector(
            onTap: onSelected,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: focused
                    ? accent
                    : selected
                    ? accent.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(theme.radius + 6),
                border: Border.all(
                  color: focused || selected ? accent : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: <Widget>[
                  // A check on the language that is playing, and nothing at
                  // all on the others: an empty checkbox on every row read as
                  // "none of these is on". The box keeps the labels aligned.
                  SizedBox(
                    width: 24,
                    child: selected
                        ? Icon(
                            Icons.check,
                            color: focused ? theme.onFocusColor : accent,
                          )
                        : null,
                  ),
                  const SizedBox(width: 9),
                  // A long label ("Französisch (5.1, AD)") wraps rather than
                  // overflowing the sidebar.
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: focused ? theme.onFocusColor : text,
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
