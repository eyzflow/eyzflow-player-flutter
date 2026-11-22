import 'package:flutter/material.dart';

import '../l10n/streaming_l10n.dart';
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
  });

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
                return Column(
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
                    TextButton.icon(
                      onPressed: widget.cast.stop,
                      icon: const Icon(Icons.stop),
                      label: Text(streamingL10n.castStop),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          ),
        ],
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
