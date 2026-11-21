import 'package:flutter/material.dart';
import '../l10n/streaming_l10n.dart';

class NoPlayerSurface extends StatelessWidget {
  const NoPlayerSurface({super.key, required this.operatingSystem});

  final String? operatingSystem;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Text(
        streamingL10n.playbackNotAvailableOnPlatform,
        style: const TextStyle(color: Colors.white),
        textAlign: TextAlign.center,
      ),
    ),
  );
}
