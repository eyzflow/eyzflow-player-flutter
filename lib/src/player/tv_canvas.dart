import 'package:flutter/widgets.dart';

/// Lays TV UI out on a canvas [canvasWidth] wide and draws it scaled up to
/// the space it has, so it looks the same on every TV: the controls overlay,
/// its panels and skip button, the ad layer and the end screen.
///
/// Their sizes are logical pixels on Android TV, which reports 960 whatever
/// the panel. Tizen reports 1920, where the same numbers drew everything at
/// half size. Narrower than the canvas (a test, a small window), nothing scales.
/// The canvas's [MediaQuery] is the canvas's own size, so widgets inside that
/// size themselves from the screen (the loading spinner) are not scaled twice.
class TvCanvas extends StatelessWidget {
  /// [scale] null works it out from the space the canvas is given.
  const TvCanvas({super.key, this.scale, required this.child});

  static const double canvasWidth = 960;

  /// The scale for a canvas laid out in [constraints]: 1 up to
  /// [canvasWidth], the width over it beyond.
  static double scaleFor(BoxConstraints constraints) =>
      constraints.hasBoundedWidth && constraints.maxWidth > canvasWidth
      ? constraints.maxWidth / canvasWidth
      : 1;

  final double? scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale == 1) return child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double scale = this.scale ?? scaleFor(constraints);
        if (scale == 1) return child;
        final Size canvas = Size(
          constraints.maxWidth / scale,
          constraints.maxHeight / scale,
        );
        final MediaQueryData media = MediaQuery.of(context);
        return FittedBox(
          fit: BoxFit.fill,
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: canvas,
            child: MediaQuery(
              data: media.copyWith(
                size: canvas,
                padding: media.padding / scale,
                viewPadding: media.viewPadding / scale,
                viewInsets: media.viewInsets / scale,
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
