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
          child: Container(
            width: 270,
            alignment: Alignment.center,
            color: theme.panelColor,
            padding: const EdgeInsets.all(18),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      color: theme.textColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
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
          return GestureDetector(
            onTap: onSelected,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: focused
                    ? theme.focusColor
                    : text.withValues(alpha: text.a * 0.1),
                borderRadius: BorderRadius.circular(theme.radius),
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
                            color: focused
                                ? theme.onFocusColor
                                : text.withValues(alpha: text.a * 0.7),
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
