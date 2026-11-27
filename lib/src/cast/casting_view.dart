import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/language_names.dart';
import '../l10n/streaming_l10n.dart';
import '../player/player_options.dart';
import '../player/player_policy.dart';
import '../player/track_panel.dart';
import 'cast_backend.dart';
import 'cast_controller.dart';

/// The phone while the TV plays: the poster, "Playing on …", play/pause, a
/// seek bar and Stop casting. Stop casting hands playback back to the phone;
/// Close stops casting and closes the player, so the stream does not stay
/// counted against the plan.
class CastingView extends StatefulWidget {
  const CastingView({
    super.key,
    required this.cast,
    required this.title,
    this.poster,
    required this.onClose,
    this.theme = const PlayerControlsTheme(),
  });

  /// The player's controls theme, for the audio and subtitle panels.
  final PlayerControlsTheme theme;

  final EYZFlowCastController cast;
  final String title;
  final Uri? poster;
  final VoidCallback onClose;

  @override
  State<CastingView> createState() => _CastingViewState();
}

class _CastingViewState extends State<CastingView> {
  /// The slider's value while dragging; the TV's position otherwise.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.poster != null)
            Opacity(
              opacity: 0.25,
              child: Image.network(
                widget.poster.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          SafeArea(
            child: ListenableBuilder(
              listenable: widget.cast,
              builder: (context, _) {
                final state = widget.cast.state;
                final (target, playback) = switch (state) {
                  CastActive(:final target, :final playback) => (
                    target,
                    playback,
                  ),
                  CastConnecting(:final target) => (target, null),
                  _ => (null, null),
                };
                final duration = playback?.duration;
                final position = playback?.position ?? Duration.zero;
                final max = (duration?.inMilliseconds ?? 0).toDouble();
                final controls = Column(
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: IconButton(
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: streamingL10n.closePlayer,
                      ),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.cast_connected,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: text.titleLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (target != null)
                      Text(
                        playback == null
                            ? streamingL10n.castConnecting(target.name)
                            : streamingL10n.castPlayingOn(target.name),
                        style: text.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                    const Spacer(),
                    if (playback != null && max > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Text(
                              _time(position),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            Expanded(
                              child: Slider(
                                value:
                                    (_dragging ??
                                            position.inMilliseconds.toDouble())
                                        .clamp(0, max),
                                max: max,
                                onChanged: (value) =>
                                    setState(() => _dragging = value),
                                onChangeEnd: (value) {
                                  setState(() => _dragging = null);
                                  widget.cast.seek(
                                    Duration(milliseconds: value.round()),
                                  );
                                },
                              ),
                            ),
                            Text(
                              _time(duration!),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    if (playback != null)
                      IconButton(
                        iconSize: 56,
                        onPressed: playback.state == CastPlayerState.playing
                            ? widget.cast.pause
                            : widget.cast.play,
                        icon: Icon(
                          playback.state == CastPlayerState.playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: Colors.white,
                        ),
                      )
                    else
                      const SizedBox.square(
                        dimension: 56,
                        child: Padding(
                          padding: EdgeInsets.all(14),
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (playback != null && playback.tracks.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final kind in CastTrackKind.values)
                            if (playback.tracks.any(
                              (t) => t.kind == kind && t.isOffered,
                            ))
                              TextButton.icon(
                                onPressed: () => _showPanel(context, kind),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                ),
                                icon: Icon(
                                  kind == CastTrackKind.audio
                                      ? Icons.audiotrack
                                      : Icons.subtitles,
                                ),
                                label: Text(
                                  kind == CastTrackKind.audio
                                      ? streamingL10n.audio
                                      : streamingL10n.subtitles,
                                ),
                              ),
                        ],
                      ),
                    TextButton.icon(
                      onPressed: widget.cast.stop,
                      icon: const Icon(Icons.stop),
                      label: Text(streamingL10n.castStop),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
                return CustomScrollView(
                  slivers: [
                    SliverFillRemaining(hasScrollBody: false, child: controls),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The phone's audio or subtitle panel over the casting screen; a tap
  /// switches the TV and closes it.
  Future<void> _showPanel(BuildContext context, CastTrackKind kind) {
    final cast = widget.cast;
    final theme = widget.theme;
    final textStyle = DefaultTextStyle.of(context).style;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black38,
      pageBuilder: (dialog, _, _) => ListenableBuilder(
        listenable: cast,
        builder: (dialog, _) {
          final state = cast.state;
          if (state is! CastActive) {
            final route = ModalRoute.of(dialog)!;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (route.isActive) route.navigator?.removeRoute(route);
            });
            return const SizedBox.shrink();
          }
          final playback = state.playback;
          // A forced track playing counts as Off: it is not a choice.
          final tracks = [
            for (final t in playback.tracks)
              if (t.kind == kind && t.isOffered) t,
          ];
          final isAudio = kind == CastTrackKind.audio;
          void pick(VoidCallback switchTv) {
            Navigator.of(dialog).pop();
            switchTv();
          }

          final rows = <TrackPanelRow>[
            if (!isAudio)
              (
                label: streamingL10n.subtitlesOff,
                selected:
                    playback.hasActiveTrackIds &&
                    !tracks.any((t) => playback.activeTrackIds.contains(t.id)),
                onSelected: () => pick(() => cast.selectSubtitles(null)),
              ),
            for (final t in tracks)
              (
                label: castTrackLabel(t),
                selected: playback.activeTrackIds.contains(t.id),
                onSelected: () => pick(
                  () => isAudio
                      ? cast.selectAudio(t.id)
                      : cast.selectSubtitles(t.id),
                ),
              ),
          ];
          final selected = rows.indexWhere((r) => r.selected);
          return SafeArea(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.goBack): () async {
                  // Android can also deliver a route pop for the same press.
                  await WidgetsBinding.instance.endOfFrame;
                  if (dialog.mounted &&
                      ModalRoute.isCurrentOf(dialog) == true) {
                    Navigator.of(dialog).pop();
                  }
                },
              },
              child: DefaultTextStyle(
                style: textStyle,
                child: TrackPanel(
                  theme: theme,
                  title: isAudio
                      ? streamingL10n.audio
                      : streamingL10n.subtitles,
                  rows: rows,
                  selectedRow: selected == -1 ? 0 : selected,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// A cast track's row label, as the phone's panel words it: the language name
/// with what tells two renditions apart ("Arabic (5.1)", "French (AD)"),
/// from receiver metadata, with the track name as a fallback.
String castTrackLabel(CastTrack track) {
  final String? name = track.name;
  final String? language = track.language == null
      ? null
      : EYZFlowLanguageNames.languageName(track.language!);
  if (language == null) return name ?? track.language ?? '${track.id}';
  if (track.kind != CastTrackKind.audio) return language;
  final raw = name ?? '';
  final layout = track.channelCount == null
      ? RegExp(r'\b[57]\.1\b').firstMatch(raw)?.group(0)
      : surroundLayout(track.channelCount);
  // "alternate" alone can be a dub or commentary as well as description.
  final description =
      track.roles.contains('description') ||
      RegExp(
        r'\b(AD|audio description|audiodeskription)\b',
        caseSensitive: false,
      ).hasMatch(raw);
  return audioTrackLabel(language, layout: layout, description: description);
}
