import 'package:flutter/material.dart';

/// The player's loading spinner, sized like Apple's `SizedLoadingArcsView`:
/// phone 40, tablet 50, TV 80.
///
/// Package-owned so `eyzflow_player` does not depend on the app design
/// system. The TV size is in points on a 1920-wide canvas and is scaled by the
/// reported width: Android TV reports 960 logical pixels whatever the panel,
/// so an unscaled 80 would draw twice as large there. Tizen reports 1920.
class PlayerLoadingIndicator extends StatelessWidget {
  const PlayerLoadingIndicator({super.key, this.isTv = false});

  final bool isTv;

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final double edge = isTv
        ? (size.width > 0 ? 80 * size.width / 1920 : 80)
        : (size.shortestSide >= 600 ? 50 : 40);
    return SizedBox.square(
      dimension: edge,
      child: const CircularProgressIndicator(),
    );
  }
}
