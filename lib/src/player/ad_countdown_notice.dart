import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../ads/ad_countdown.dart';

/// The corner notice before a mid-roll: "Ad in 5" … "Ad in 1" (the length is
/// the config's `ads.countdownSeconds`).
///
/// Never takes a touch or the remote's focus, so the controls under it work
/// as before; on TV it stays on screen while the controls are hidden. Read
/// out by screen readers as it changes.
class AdCountdownNotice extends StatelessWidget {
  const AdCountdownNotice({super.key, required this.seconds, this.liftedBy});

  /// Seconds until the break, or null for no notice.
  final ValueListenable<int?> seconds;

  /// While this holds something (a skip button's signal), the notice moves
  /// up above it.
  final ValueListenable<Object?>? liftedBy;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable?>[seconds, liftedBy]),
    builder: (BuildContext context, _) {
      final int? left = seconds.value;
      if (left == null) {
        return const Positioned(right: 0, bottom: 0, child: SizedBox.shrink());
      }
      return Positioned(
        right: 16,
        bottom:
            (liftedBy?.value == null ? 72 : 128) +
            MediaQuery.paddingOf(context).bottom,
        child: IgnorePointer(
          child: ExcludeFocus(
            child: Semantics(
              liveRegion: true,
              container: true,
              child: DecoratedBox(
                key: const ValueKey<String>('eyzflow-ad-countdown'),
                decoration: BoxDecoration(
                  color: const Color(0xB8000000),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Text(
                    adCountdownLabel(left),
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
