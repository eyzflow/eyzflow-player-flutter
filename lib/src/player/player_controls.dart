import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../l10n/language_names.dart';

import '../bloc/player_controls_bloc.dart';
import '../core/thumbnails.dart';
import 'player_policy.dart';
import '../l10n/streaming_l10n.dart';
import 'player_loading_indicator.dart';
import 'player_options.dart';

/// How long the overlay takes to fade in or out.
const Duration _fadeDuration = Duration(milliseconds: 250);

/// One selectable row of a track panel: the track to switch to, and the name
/// to show for it. A `null` [trackId] is the subtitles panel's own `Off` row.
typedef _NamedTrack = ({int? trackId, String label});

/// The audio tracks a panel can offer: those whose language code resolves to
/// a name a viewer can read (see [EyzflowLanguageNames.languageName], which
/// answers `null` for `und`, `zxx` and the untagged renditions EYZFlow emits
/// as `un`).
///
/// Read by the panel, by the button that opens it, and by the D-pad row
/// model, so the three can never disagree — a button that offered an empty
/// panel put a bare title on screen with no row for focus to land on.
List<_NamedTrack> _namedAudioTracks(
  List<PlayerAudioTrack> tracks,
) => <_NamedTrack>[
  for (final PlayerAudioTrack t in tracks)
    if (EyzflowLanguageNames.languageName(t.language) case final String name)
      (trackId: t.trackId, label: _audioLabel(name, t)),
];

/// "Französisch (5.1, AD)": the qualifiers that tell two renditions of one
/// language apart.
String _audioLabel(String name, PlayerAudioTrack t) {
  final List<String> tags = <String>[
    if (t.surroundLabel case final String layout) layout,
    if (t.isAudioDescription) 'AD',
  ];
  return tags.isEmpty ? name : '$name (${tags.join(', ')})';
}

/// The text tracks a panel can offer.
///
/// The `Off` row is deliberately not one of them: it belongs to the panel, and
/// a panel that could only ever say "Off" is nothing to offer, which is why
/// the subtitles button hides when this comes back empty.
List<_NamedTrack> _namedTextTracks(
  List<PlayerTextTrack> tracks,
) => <_NamedTrack>[
  for (final PlayerTextTrack t in tracks)
    if (EyzflowLanguageNames.languageName(t.language) case final String name)
      (trackId: t.trackId, label: t.isSdh ? '$name (SDH)' : name),
];

/// Focus arriving on a control restarts the idle timer, but must never wake a
/// hidden overlay.
///
/// Restoring focus is not viewer input: after the overlay hides, or a track
/// panel closes over the node its rows were focusing, the view puts focus
/// back on a control — and dispatching plain activity there pulled the
/// overlay straight back onto the screen.
void _focusMoved(PlayerControlsBloc bloc) {
  if (bloc.state.visible) bloc.add(const PlayerControlsActivity());
}

/// Every control the overlay can put focus on, grouped into the rows the
/// D-pad walks between.
///
/// Focus on a TV is a grid, not a reading order: the viewer presses down and
/// expects the next band of controls, whatever its horizontal position.
/// Flutter's directional traversal decides that geometrically, which drops
/// controls that do not overlap the source's horizontal extent — the
/// audio/subtitle pair sits far right of the transport, so it was
/// unreachable. These rows are the model instead; traversal only runs
/// *within* a row, where geometry is right.
final class _ControlNodes {
  _ControlNodes();

  final FocusNode back = FocusNode(debugLabel: 'controls.back');
  final FocusNode skipBack = FocusNode(debugLabel: 'controls.skipBack');
  final FocusNode playPause = FocusNode(debugLabel: 'controls.playPause');
  final FocusNode skipForward = FocusNode(debugLabel: 'controls.skipForward');
  final FocusNode audio = FocusNode(debugLabel: 'controls.audio');
  final FocusNode subtitles = FocusNode(debugLabel: 'controls.subtitles');
  final FocusNode progress = FocusNode(debugLabel: 'controls.progress');

  late final List<FocusNode> all = <FocusNode>[
    back,
    skipBack,
    playPause,
    skipForward,
    audio,
    subtitles,
    progress,
  ];

  /// The rows as they currently stand on screen.
  ///
  /// The audio/subtitle pair shrinks, or goes altogether, when a panel would
  /// have nothing to offer — and the D-pad must not walk onto a button that
  /// is not there: focusing a detached node loses focus outright, which reads
  /// as a dead remote until the reclaim net catches it a frame later.
  List<List<FocusNode>> visibleRows({
    required bool hasAudio,
    required bool hasSubtitles,
  }) => <List<FocusNode>>[
    <FocusNode>[back],
    <FocusNode>[skipBack, playPause, skipForward],
    <FocusNode>[if (hasAudio) audio, if (hasSubtitles) subtitles],
    <FocusNode>[progress],
  ]..removeWhere((List<FocusNode> row) => row.isEmpty);

  /// Where focus lands when [row] is entered from above or below. Carrying
  /// the column across instead would drop the viewer on skip-back coming
  /// down from the title bar, and on subtitles coming down from play/pause.
  int entryColumn(List<FocusNode> row) {
    final int transport = row.indexOf(playPause);
    return transport == -1 ? 0 : transport;
  }

  void dispose() {
    for (final FocusNode node in all) {
      node.dispose();
    }
  }
}

/// The TV player controls overlay: an auto-hiding transport, a scrubbable
/// progress bar, and audio/subtitle pickers, all driven by
/// [PlayerControlsBloc] and the TV remote (Samsung on Tizen, Android TV
/// elsewhere).
class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.title,
    this.onBack,
    this.thumbnailsUrl,
    this.thumbnailLoader,
    this.theme = const PlayerControlsTheme(),
    this.showControls = true,
  });

  final String title;
  final VoidCallback? onBack;

  /// The stream's WebVTT thumbnail track. While a skip previews or the bar
  /// is dragged, the frame of the previewed time shows above the thumb.
  /// Absent, or failing to load, the bar works as before.
  final Uri? thumbnailsUrl;

  /// Loads [thumbnailsUrl]; [ThumbnailLoader.shared] when null. A test seam.
  final ThumbnailLoader? thumbnailLoader;

  /// Colours and radius, from a player config's theme.
  final PlayerControlsTheme theme;

  /// False shows no overlay (a player config's `controls: false`): Back
  /// closes the player, media keys play, pause and skip, and left/right skip.
  final bool showControls;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final _ControlNodes _nodes = _ControlNodes();

  /// The last state the focus listener saw, so it reacts to a transition
  /// rather than only a destination.
  late PlayerControlsState _previous;

  ThumbnailTrack? _thumbnails;

  @override
  void initState() {
    super.initState();
    _previous = context.read<PlayerControlsBloc>().state;
    unawaited(_loadThumbnails());
    FocusManager.instance.addListener(_onFocusChanged);
    // The first frame has no render objects to focus yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusPlayPause());
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    _nodes.dispose();
    super.dispose();
  }

  Future<void> _loadThumbnails() async {
    final Uri? url = widget.thumbnailsUrl;
    if (url == null) return;
    final ThumbnailTrack? track =
        await (widget.thumbnailLoader ?? ThumbnailLoader.shared).load(url);
    if (mounted && track != null) setState(() => _thumbnails = track);
  }

  void _focusPlayPause() {
    if (mounted) _nodes.playPause.requestFocus();
  }

  /// Puts focus back on a control whenever it lands nowhere.
  ///
  /// Removing a focused node — a track panel closing, the transport
  /// rebuilding — drops primary focus onto the enclosing scope, which is not
  /// a control: the remote then appears dead until the viewer stumbles onto
  /// something. A scope holding primary focus is exactly that state, and the
  /// only one worth reclaiming; a real control elsewhere (a dialog over the
  /// player) is left alone.
  void _onFocusChanged() {
    if (!mounted) return;
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused is! FocusScopeNode) return;
    final PlayerControlsState state = context.read<PlayerControlsBloc>().state;
    // A panel owns focus through its own rows, which the row model does not
    // know about.
    if (state.activePanel != PlayerPanel.none) return;
    // Deferred: requesting focus from inside a focus notification re-enters
    // this listener. By the next frame the tree has settled, so the check is
    // repeated there and only a still-empty focus is reclaimed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final FocusNode? settled = FocusManager.instance.primaryFocus;
      if (settled == null || settled is FocusScopeNode) _focusPlayPause();
    });
  }

  /// Where focus currently sits, as `(row, column)`, or `null` when it has
  /// left the overlay entirely.
  (int, int)? _locateFocus(List<List<FocusNode>> rows) {
    final FocusNode? focused = FocusManager.instance.primaryFocus;
    if (focused == null) return null;
    for (int row = 0; row < rows.length; row++) {
      final int column = rows[row].indexOf(focused);
      if (column != -1) return (row, column);
    }
    return null;
  }

  /// Moves focus one row up or down, landing on that row's entry control.
  void _moveRow(List<List<FocusNode>> rows, int delta) {
    final (int, int)? location = _locateFocus(rows);
    if (location == null) {
      // Focus was lost — this is the net that keeps a control always lit.
      _focusPlayPause();
      return;
    }
    final int row = (location.$1 + delta).clamp(0, rows.length - 1);
    if (row == location.$1) return;
    rows[row][_nodes.entryColumn(rows[row])].requestFocus();
  }

  /// Moves focus left or right inside the current row, stopping at its ends.
  ///
  /// The row model owns this too rather than deferring to Flutter's
  /// directional traversal: that searches the enclosing focus *scope*, which
  /// a [FocusTraversalGroup] does not bound, so a press at the end of a row
  /// would jump to whatever sits nearest in that direction anywhere on
  /// screen.
  void _moveColumn(List<List<FocusNode>> rows, int delta) {
    final (int, int)? location = _locateFocus(rows);
    if (location == null) {
      _focusPlayPause();
      return;
    }
    final List<FocusNode> row = rows[location.$1];
    final int column = (location.$2 + delta).clamp(0, row.length - 1);
    if (column == location.$2) return;
    row[column].requestFocus();
  }

  /// Handles the arrow keys the row model owns, and reports whether it did.
  ///
  /// Anything it declines falls through to Flutter's own traversal, which is
  /// what moves focus left and right inside a row.
  bool _handleArrow(LogicalKeyboardKey key, PlayerControlsBloc bloc) {
    final PlayerControlsState state = bloc.state;
    final bool isLeft = key == LogicalKeyboardKey.arrowLeft;
    final bool isRight = key == LogicalKeyboardKey.arrowRight;

    // Hidden, an arrow only wakes the overlay — the caller has already
    // dispatched that activity. Scrubbing belongs to the progress bar, so
    // the press is consumed here rather than also moving focus on the way in;
    // revealing the overlay puts focus on the transport regardless.
    if (!state.visible) return true;

    // An open panel is a vertical list of its own; leave it to traversal.
    if (state.activePanel != PlayerPanel.none) return false;

    final List<List<FocusNode>> rows = _nodes.visibleRows(
      hasAudio: _namedAudioTracks(state.audioTracks).isNotEmpty,
      hasSubtitles: _namedTextTracks(state.textTracks).isNotEmpty,
    );

    if (key == LogicalKeyboardKey.arrowUp) {
      _moveRow(rows, -1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveRow(rows, 1);
      return true;
    }
    if (!isLeft && !isRight) return false;
    // On the progress row the arrows are the scrub control.
    if (_nodes.progress.hasFocus) {
      bloc.add(PlayerControlsSkipBy(isRight ? 1 : -1));
      return true;
    }
    _moveColumn(rows, isRight ? 1 : -1);
    return true;
  }

  /// Keeps a control lit across the state changes that used to drop focus:
  /// the overlay reappearing, and a track panel closing over the nodes its
  /// rows were focusing.
  void _restoreFocus(PlayerControlsState previous, PlayerControlsState state) {
    if (!previous.visible && state.visible) {
      // Reappearing resets to the transport, the control a viewer expects to
      // press first.
      if (_fullyHidden) setState(() => _fullyHidden = false);
      _focusPlayPause();
      return;
    }
    if (previous.visible && !state.visible) {
      // The reset to the transport waits for the fade to finish: moving focus
      // now shows the halo jumping across a still-visible overlay. See the
      // AnimatedOpacity's onEnd below.
      return;
    }
    if (previous.activePanel != PlayerPanel.none &&
        state.activePanel == PlayerPanel.none) {
      // The panel's own rows held focus and have just left the tree.
      final FocusNode opener = previous.activePanel == PlayerPanel.audio
          ? _nodes.audio
          : _nodes.subtitles;
      opener.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PlayerControlsBloc>();
    if (!widget.showControls) {
      return _BareRemote(bloc: bloc, onBack: () => _leave(context));
    }
    return _ThemeScope(theme: widget.theme, child: _buildOverlay(bloc));
  }

  Widget _buildOverlay(PlayerControlsBloc bloc) {
    return BlocConsumer<PlayerControlsBloc, PlayerControlsState>(
      listenWhen: (previous, current) =>
          previous.visible != current.visible ||
          previous.activePanel != current.activePanel,
      listener: (context, state) {
        final PlayerControlsState previous = _previous;
        _previous = state;
        _restoreFocus(previous, state);
      },
      builder: (context, state) {
        // Android — Android TV included — delivers the Back button as a
        // navigation pop, not as a key event: it never reaches the
        // `goBack`/`escape` branch below, so it popped the whole player even
        // with a track panel open. Tizen sends a real key, which is why the
        // ladder only worked there. Both now run the same one.
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (didPop) return;
            _handleBack(context, bloc);
          },
          child: _RemoteListener(
            isVisible: state.visible,
            onActivity: () => bloc.add(const PlayerControlsActivity()),
            onPlayPause: () => bloc.add(const PlayerControlsPlayPauseToggled()),
            onSkipForward: () => bloc.add(const PlayerControlsSkipBy(1)),
            onSkipBackward: () => bloc.add(const PlayerControlsSkipBy(-1)),
            onBack: () => _handleBack(context, bloc),
            onArrow: (LogicalKeyboardKey key) => _handleArrow(key, bloc),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // With the overlay off screen there is no elapsed time to sit
                // beside, and a stall would otherwise show nothing at all.
                if (state.isBuffering && _fullyHidden)
                  const Center(child: PlayerLoadingIndicator(isTv: true)),
                IgnorePointer(
                  ignoring: !state.visible,
                  child: AnimatedOpacity(
                    opacity: state.visible ? 1 : 0,
                    duration: _fadeDuration,
                    onEnd: () {
                      if (!mounted || state.visible || _fullyHidden) return;
                      setState(() => _fullyHidden = true);
                      // Only now: the overlay is off screen, so the focus
                      // move cannot be seen.
                      _focusPlayPause();
                    },
                    child: _ControlsScaffold(
                      title: widget.title,
                      onBack: widget.onBack,
                      nodes: _nodes,
                      thumbnails: _thumbnails,
                    ),
                  ),
                ),
                if (state.activePanel != PlayerPanel.none)
                  _TrackPanel(panel: state.activePanel),
              ],
            ),
          ),
        );
      },
    );
  }

  /// True once the overlay has finished fading out — not merely once the
  /// state says hidden. Anything that would be seen mid-fade waits for this.
  bool _fullyHidden = false;

  /// Set while a Back press is being served, and cleared on the next frame,
  /// so the second delivery of the same press is ignored.
  bool _backServed = false;

  /// Walks one rung down the dismiss ladder: a track panel first, then the
  /// overlay, then the player itself.
  ///
  /// Android TV delivers one Back press twice — as a `goBack` key event and
  /// as a route pop — and taking a rung for each dismissed the panel and the
  /// overlay together. Both deliveries land between the same pair of frames,
  /// so the first serves the press and the second is dropped. Tizen, which
  /// sends only the key, is unaffected.
  // ponytail: two genuine presses within one frame (~16 ms) would coalesce
  // into one. If a remote ever repeats that fast, pairing key down/up is the
  // upgrade.
  void _handleBack(BuildContext context, PlayerControlsBloc bloc) {
    if (_backServed) return;
    _backServed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _backServed = false);

    final PlayerControlsState state = bloc.state;
    // A track panel is dismissed by Back exactly as OK dismisses it, and
    // neither touches the player.
    if (state.activePanel != PlayerPanel.none) {
      bloc.add(const PlayerControlsPanelClosed());
      return;
    }
    if (state.visible) {
      bloc.add(const PlayerControlsHideRequested());
      return;
    }
    _leave(context);
  }

  void _leave(BuildContext context) {
    final VoidCallback? onBack = widget.onBack;
    if (onBack != null) {
      onBack();
    } else {
      // pop, not maybePop: maybePop consults the PopScope above and would
      // hand the press straight back to this method.
      Navigator.of(context).pop();
    }
  }
}

/// The overlay's [PlayerControlsTheme], for the widgets inside it.
class _ThemeScope extends InheritedWidget {
  const _ThemeScope({required this.theme, required super.child});

  final PlayerControlsTheme theme;

  static PlayerControlsTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ThemeScope>()?.theme ??
      const PlayerControlsTheme();

  @override
  bool updateShouldNotify(_ThemeScope old) => old.theme != theme;
}

/// The remote without an overlay, for a config with `controls: false`.
class _BareRemote extends StatelessWidget {
  const _BareRemote({required this.bloc, required this.onBack});

  final PlayerControlsBloc bloc;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) onBack();
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final LogicalKeyboardKey key = event.logicalKey;
          if (key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.escape) {
            onBack();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.mediaPlay ||
              key == LogicalKeyboardKey.mediaPause ||
              key == LogicalKeyboardKey.mediaPlayPause ||
              key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter) {
            bloc.add(const PlayerControlsPlayPauseToggled());
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.mediaFastForward ||
              key == LogicalKeyboardKey.arrowRight) {
            bloc.add(const PlayerControlsSkipBy(1));
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.mediaRewind ||
              key == LogicalKeyboardKey.arrowLeft) {
            bloc.add(const PlayerControlsSkipBy(-1));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Wraps the overlay in a [FocusableActionDetector] that turns TV-remote
/// keys into Bloc events. Any key wakes the overlay; media keys and D-pad
/// left/right act even while hidden. System keys are never intercepted.
class _RemoteListener extends StatelessWidget {
  const _RemoteListener({
    required this.isVisible,
    required this.onArrow,
    required this.onActivity,
    required this.onPlayPause,
    required this.onSkipForward,
    required this.onSkipBackward,
    required this.onBack,
    required this.child,
  });

  /// Whether the overlay is currently on screen. While it is, arrow keys
  /// belong to focus traversal; while it is hidden there is nothing to
  /// traverse, so they seek.
  final bool isVisible;

  /// Offered every arrow key. Returns true when the row model consumed it;
  /// false lets Flutter's traversal move focus within the row.
  final bool Function(LogicalKeyboardKey) onArrow;
  final VoidCallback onActivity;
  final VoidCallback onPlayPause;
  final VoidCallback onSkipForward;
  final VoidCallback onSkipBackward;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final LogicalKeyboardKey key = event.logicalKey;

        // Never swallow system keys.
        if (key == LogicalKeyboardKey.audioVolumeUp ||
            key == LogicalKeyboardKey.audioVolumeDown ||
            key == LogicalKeyboardKey.audioVolumeMute ||
            key == LogicalKeyboardKey.power) {
          return KeyEventResult.ignored;
        }

        if (key == LogicalKeyboardKey.goBack ||
            key == LogicalKeyboardKey.escape) {
          onBack();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.mediaPlay ||
            key == LogicalKeyboardKey.mediaPause ||
            key == LogicalKeyboardKey.mediaPlayPause) {
          onActivity();
          onPlayPause();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.mediaFastForward) {
          onActivity();
          onSkipForward();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.mediaRewind) {
          onActivity();
          onSkipBackward();
          return KeyEventResult.handled;
        }

        // Arrows go to the row model first: it owns up/down between rows and
        // the scrub on the progress row, and declines the rest so traversal
        // can move focus left and right within a row.
        if (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) {
          onActivity();
          return onArrow(key) ? KeyEventResult.handled : KeyEventResult.ignored;
        }

        // Wake the overlay on any other key, then let focus traversal /
        // ActivateIntent handle it normally.
        onActivity();
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

class _ControlsScaffold extends StatelessWidget {
  const _ControlsScaffold({
    required this.title,
    required this.onBack,
    required this.nodes,
    this.thumbnails,
  });

  final String title;
  final VoidCallback? onBack;
  final _ControlNodes nodes;
  final ThumbnailTrack? thumbnails;

  @override
  Widget build(BuildContext context) {
    final Color bar = _ThemeScope.of(context).barColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            // The top is lighter: black54 over the default black87.
            bar.withValues(alpha: bar.a * 138 / 221),
            Colors.transparent,
            Colors.transparent,
            bar,
          ],
          stops: const <double>[0, 0.25, 0.6, 1],
        ),
      ),
      child: Column(
        children: <Widget>[
          _TopBar(title: title, onBack: onBack, nodes: nodes),
          Expanded(child: _MiddleRow(nodes: nodes)),
          _BottomBar(nodes: nodes, thumbnails: thumbnails),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.nodes,
  });

  final String title;
  final VoidCallback? onBack;
  final _ControlNodes nodes;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PlayerControlsBloc>();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          _FocusIconButton(
            focusNode: nodes.back,
            icon: Icons.arrow_back,
            semanticLabel: streamingL10n.back,
            onPressed: () {
              if (onBack != null) {
                onBack!();
              } else {
                Navigator.of(context).maybePop();
              }
            },
            onFocused: () => _focusMoved(bloc),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _ThemeScope.of(context).textColor,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiddleRow extends StatelessWidget {
  const _MiddleRow({required this.nodes});

  final _ControlNodes nodes;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PlayerControlsBloc>();
    return BlocBuilder<PlayerControlsBloc, PlayerControlsState>(
      buildWhen: (a, b) => a.isPlaying != b.isPlaying,
      builder: (context, state) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _FocusIconButton(
              key: const Key('player_controls_skip_back'),
              focusNode: nodes.skipBack,
              // The real step is 15 s. Material has no replay_15, so we use the
              // closest glyph (replay_10) and keep the accurate count in the
              // label rather than implying a 10 s step in the icon.
              icon: Icons.replay_10,
              semanticLabel: streamingL10n.rewind15Seconds,
              size: 36,
              onPressed: () => bloc.add(const PlayerControlsSkipBy(-1)),
              onFocused: () => _focusMoved(bloc),
            ),
            const SizedBox(width: 36),
            _FocusIconButton(
              key: const Key('player_controls_play_pause'),
              focusNode: nodes.playPause,
              icon: state.isPlaying ? Icons.pause : Icons.play_arrow,
              semanticLabel: state.isPlaying
                  ? streamingL10n.pause
                  : streamingL10n.play,
              size: 48,
              onPressed: () => bloc.add(const PlayerControlsPlayPauseToggled()),
              onFocused: () => _focusMoved(bloc),
            ),
            const SizedBox(width: 48),
            _FocusIconButton(
              key: const Key('player_controls_skip_forward'),
              focusNode: nodes.skipForward,
              // 15 s step; Material has no forward_15, so forward_10 is the
              // closest glyph and the label carries the accurate count.
              icon: Icons.forward_10,
              semanticLabel: streamingL10n.forward15Seconds,
              size: 36,
              onPressed: () => bloc.add(const PlayerControlsSkipBy(1)),
              onFocused: () => _focusMoved(bloc),
            ),
          ],
        );
      },
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.nodes, this.thumbnails});

  final _ControlNodes nodes;
  final ThumbnailTrack? thumbnails;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PlayerControlsBloc>();
    final PlayerControlsTheme theme = _ThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: BlocBuilder<PlayerControlsBloc, PlayerControlsState>(
        builder: (context, state) {
          // A button whose panel would have nothing to offer is not shown:
          // one language still is, so the viewer can see what is playing.
          final bool hasAudio = _namedAudioTracks(state.audioTracks).isNotEmpty;
          final bool hasSubtitles = _namedTextTracks(
            state.textTracks,
          ).isNotEmpty;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (hasAudio)
                    _FocusIconButton(
                      key: const Key('player_controls_audio'),
                      focusNode: nodes.audio,
                      icon: Icons.audiotrack,
                      semanticLabel: streamingL10n.audio,
                      onPressed: () => bloc.add(
                        const PlayerControlsPanelOpened(PlayerPanel.audio),
                      ),
                      onFocused: () => _focusMoved(bloc),
                    ),
                  if (hasAudio && hasSubtitles) const SizedBox(width: 12),
                  if (hasSubtitles)
                    _FocusIconButton(
                      key: const Key('player_controls_subtitles'),
                      focusNode: nodes.subtitles,
                      icon: Icons.closed_caption,
                      semanticLabel: streamingL10n.subtitles,
                      onPressed: () => bloc.add(
                        const PlayerControlsPanelOpened(PlayerPanel.subtitles),
                      ),
                      onFocused: () => _focusMoved(bloc),
                    ),
                ],
              ),
              _ProgressSlider(
                focusNode: nodes.progress,
                position: state.position,
                duration: state.duration,
                thumbnails: thumbnails,
                previewing: state.isPreviewing,
                onChangeStart: (_) =>
                    bloc.add(const PlayerControlsScrubStarted()),
                onChangeEnd: (value) => bloc.add(
                  PlayerControlsScrubEnded(
                    Duration(milliseconds: value.round()),
                  ),
                ),
              ),
              // Under the bar, where the eye already is after reading the
              // thumb — not competing with the track buttons above it.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: <Widget>[
                    Text(
                      _format(state.position),
                      style: TextStyle(color: theme.textColor, fontSize: 12),
                    ),
                    // Beside the elapsed time rather than centred: in the
                    // middle it sat on top of the transport, competing with
                    // the control the viewer is looking at.
                    if (state.isBuffering) ...<Widget>[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.textColor,
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _format(state.duration),
                      style: TextStyle(
                        color: theme.textColor.withValues(
                          alpha: theme.textColor.a * 0.7,
                        ),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Owns its value for the duration of a drag.
///
/// Dispatching a seek per `onChanged` awaits `controller.seekTo` on every
/// intermediate value — a seek storm the native players cannot keep up with.
/// The drag is local; exactly one seek leaves here, from `onChangeEnd`.
class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({
    required this.position,
    required this.duration,
    required this.focusNode,
    required this.onChangeStart,
    required this.onChangeEnd,
    this.thumbnails,
    this.previewing = false,
  });

  final Duration position;
  final Duration duration;

  /// Shown above the thumb while dragging or while [previewing].
  final ThumbnailTrack? thumbnails;

  /// A skip burst is open: [position] is where it will seek.
  final bool previewing;

  /// The row model's node for the progress row. The [Slider] itself is kept
  /// out of traversal: it would eat the arrow keys to nudge its own value
  /// through `onChanged`, which never commits a seek — the overlay's own
  /// skip is what the arrows mean here.
  final FocusNode focusNode;
  final ValueChanged<double> onChangeStart;
  final ValueChanged<double> onChangeEnd;

  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  /// Non-null only while a drag is in flight.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final double max = widget.duration.inMilliseconds.toDouble();
    final double position = widget.position.inMilliseconds
        .clamp(0, max == 0 ? 0 : max)
        .toDouble();
    final double value = (_dragValue ?? position).clamp(0, max == 0 ? 0 : max);
    return Focus(
      focusNode: widget.focusNode,
      child: Builder(
        builder: (BuildContext context) {
          final bool focused = Focus.of(context).hasFocus;
          final PlayerControlsTheme theme = _ThemeScope.of(context);
          final Color focus = theme.focusColor;
          final Color? accent = theme.accentColor;
          final Widget slider = _buildSlider(max, value);
          return AnimatedContainer(
            key: const Key('player_controls_progress'),
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(theme.radius + 6),
              color: focused
                  ? focus.withValues(alpha: 0.12)
                  : Colors.transparent,
              border: Border.all(
                color: focused ? focus : Colors.transparent,
                width: 2,
              ),
              boxShadow: focused
                  ? <BoxShadow>[
                      BoxShadow(
                        blurRadius: 16,
                        color: focus.withValues(alpha: 0.38),
                      ),
                    ]
                  : null,
            ),
            child: ExcludeFocus(
              child: _withThumbnail(
                accent == null
                    ? slider
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: accent,
                          thumbColor: accent,
                          inactiveTrackColor: accent.withValues(alpha: 0.3),
                          overlayColor: accent.withValues(alpha: 0.12),
                        ),
                        child: slider,
                      ),
                max,
                value,
              ),
            ),
          );
        },
      ),
    );
  }

  /// The slider, with the previewed frame above its thumb while the viewer
  /// is choosing where to go.
  Widget _withThumbnail(Widget slider, double max, double value) {
    final ThumbnailTrack? track = widget.thumbnails;
    final bool choosing = _dragValue != null || widget.previewing;
    final ThumbnailTile? tile = track == null || !choosing || max == 0
        ? null
        : track.at(Duration(milliseconds: value.round()));
    if (tile == null) return slider;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Material's slider insets its track by the thumb's overlay radius.
        const double inset = 24;
        final double track = (constraints.maxWidth - inset * 2).clamp(
          0,
          double.infinity,
        );
        final double x = inset + track * (value / max);
        final double left = (x - _ThumbnailPreview.width / 2).clamp(
          0,
          (constraints.maxWidth - _ThumbnailPreview.width).clamp(
            0,
            double.infinity,
          ),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            slider,
            Positioned(
              left: left,
              bottom: 44,
              child: _ThumbnailPreview(tile: tile),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSlider(double max, double value) {
    return Slider(
      min: 0,
      max: max == 0 ? 1 : max,
      value: max == 0 ? 0 : value,
      onChangeStart: max == 0
          ? null
          : (double v) {
              setState(() => _dragValue = v);
              widget.onChangeStart(v);
            },
      // Must stay non-null while enabled — Material disables a Slider whose
      // onChanged is null — but it only moves the thumb now.
      onChanged: max == 0 ? null : (double v) => setState(() => _dragValue = v),
      onChangeEnd: max == 0
          ? null
          : (double v) {
              setState(() => _dragValue = null);
              widget.onChangeEnd(v);
            },
    );
  }
}

/// One frame of the thumbnail track: a tile cut from its sprite, or a whole
/// image, at a fixed width.
class _ThumbnailPreview extends StatelessWidget {
  const _ThumbnailPreview({required this.tile});

  static const double width = 192;

  final ThumbnailTile tile;

  @override
  Widget build(BuildContext context) {
    final int? tileWidth = tile.width;
    final int? tileHeight = tile.height;
    final double height =
        tileWidth != null && tileHeight != null && tileWidth > 0
        ? width * tileHeight / tileWidth
        : width * 9 / 16;
    final Widget image;
    if (tile.isSprite) {
      final double scale = width / tileWidth!;
      // The whole sprite at the tile's scale, moved so the tile sits at the
      // origin, and clipped to it.
      image = OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        minHeight: 0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: Transform.translate(
          offset: Offset(-tile.x! * scale, -tile.y! * scale),
          child: Image(
            image: NetworkImage(tile.image.toString(), scale: 1 / scale),
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      );
    } else {
      image = Image.network(
        tile.image.toString(),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Container(
      key: ValueKey<String>(
        'player_controls_thumbnail:${tile.image}#${tile.x},${tile.y}',
      ),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _ThemeScope.of(context).focusColor, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: image,
    );
  }
}

class _TrackPanel extends StatelessWidget {
  const _TrackPanel({required this.panel});

  final PlayerPanel panel;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<PlayerControlsBloc>();
    final PlayerControlsState state = bloc.state;
    final bool isAudio = panel == PlayerPanel.audio;

    final List<_NamedTrack> rows = <_NamedTrack>[
      // Only subtitles can be turned off: there is no such thing as playing a
      // film with no audio track, so the audio panel never offers the row.
      if (!isAudio) (trackId: null, label: streamingL10n.subtitlesOff),
      if (isAudio)
        ..._namedAudioTracks(state.audioTracks)
      else
        ..._namedTextTracks(state.textTracks),
    ];
    final int? selectedId = isAudio
        ? state.selectedAudioTrackId
        : state.selectedTextTrackId;

    // The panel opens on the language that is playing. With nothing checked
    // — an audio list whose active track the native player never reported —
    // it opens on the first row instead, so the sidebar never appears with a
    // dead remote.
    final int selectedRow = rows.indexWhere(
      (_NamedTrack r) => r.trackId == selectedId,
    );
    final int autofocusRow = selectedRow == -1 ? 0 : selectedRow;

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
            color: _ThemeScope.of(context).panelColor,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  isAudio ? streamingL10n.audio : streamingL10n.subtitles,
                  style: TextStyle(
                    color: _ThemeScope.of(context).textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                for (final (int index, _NamedTrack row) in rows.indexed)
                  _TrackRow(
                    label: row.label,
                    selected: row.trackId == selectedId,
                    onSelected: () => bloc.add(
                      isAudio
                          // Only the subtitles panel has a null-id row.
                          ? PlayerControlsAudioSelected(row.trackId!)
                          : PlayerControlsTextSelected(row.trackId),
                    ),
                    autofocus: index == autofocusRow,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.label,
    required this.selected,
    required this.onSelected,
    required this.autofocus,
  });

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
          final PlayerControlsTheme theme = _ThemeScope.of(context);
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
                  Text(
                    label,
                    style: TextStyle(
                      color: focused ? theme.onFocusColor : text,
                      fontSize: 15,
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

/// A focusable icon button with a TV-strength halo, wired to OK (`select` and
/// `enter`).
class _FocusIconButton extends StatelessWidget {
  const _FocusIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    required this.onFocused,
    required this.focusNode,
    this.size = 24,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onPressed;
  final VoidCallback onFocused;
  final double size;

  /// Owned by the overlay's row model, not by this button — the model has to
  /// be able to move focus here without going through the widget tree.
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: focusNode,
      onFocusChange: (focused) {
        if (focused) onFocused();
      },
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (context) {
          final bool focused = Focus.of(context).hasFocus;
          final PlayerControlsTheme theme = _ThemeScope.of(context);
          return GestureDetector(
            onTap: onPressed,
            // Unfocused, the disc is frosted glass rather than flat grey: the
            // film reads through it, and the focus halo stays the only solid
            // shape on screen.
            // ponytail: a BackdropFilter per button, always on. Cheap enough
            // on Android TV; if a weak Tizen set stutters with the overlay
            // up, drop the filter and keep the translucent fill alone.
            child: ClipOval(
              child: BackdropFilter(
                filter: focused
                    ? ImageFilter.blur()
                    : ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: focused
                        ? theme.focusColor
                        : theme.textColor.withValues(alpha: 0.12),
                    boxShadow: focused
                        ? <BoxShadow>[
                            BoxShadow(
                              blurRadius: 16,
                              color: theme.focusColor.withValues(alpha: 0.7),
                            ),
                          ]
                        : null,
                  ),
                  child: Semantics(
                    label: semanticLabel,
                    button: true,
                    child: Icon(
                      icon,
                      size: size,
                      color: focused ? theme.onFocusColor : theme.textColor,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _format(Duration d) {
  final int totalSeconds = d.inSeconds;
  final String two = totalSeconds.isNegative ? '00' : '';
  if (two.isNotEmpty) return '00:00';
  final int hours = d.inHours;
  final int minutes = d.inMinutes.remainder(60);
  final int seconds = d.inSeconds.remainder(60);
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
