import 'package:flutter/widgets.dart';

import '../player/player_policy.dart';

/// Connects the mounted phone player to its cast session after native startup.
class CastTrackScope extends InheritedWidget {
  const CastTrackScope({super.key, required this.attach, required super.child});

  final VoidCallback Function(VideoplaybackTracks player) attach;

  @override
  bool updateShouldNotify(CastTrackScope oldWidget) => false;
}
