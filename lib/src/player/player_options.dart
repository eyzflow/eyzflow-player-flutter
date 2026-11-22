import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../ads/ad_scheduler.dart';
import '../core/player_config.dart';

export '../ads/ad_scheduler.dart' show PlayerAds;

/// The TV controls overlay's colours and corner radius (Android TV and Tizen).
///
/// The default is the overlay's own look: white focus, white text, a black
/// panel. A player config's [PlayerTheme] replaces it ([fromPlayerTheme]).
@immutable
final class PlayerControlsTheme {
  const PlayerControlsTheme({
    this.accentColor,
    this.textColor = const Color(0xFFFFFFFF),
    this.panelColor = const Color.from(alpha: 0.9, red: 0, green: 0, blue: 0),
    this.barColor = const Color(0xDD000000),
    this.radius = 8,
  });

  /// A config's theme. A colour or radius that cannot be read keeps the
  /// overlay's own.
  factory PlayerControlsTheme.fromPlayerTheme(PlayerTheme theme) {
    const fallback = PlayerControlsTheme();
    return PlayerControlsTheme(
      accentColor: parseCssColor(theme.accentColor),
      textColor: parseCssColor(theme.textColor) ?? fallback.textColor,
      panelColor: parseCssColor(theme.backgroundColor) ?? fallback.panelColor,
      barColor: parseCssColor(theme.controlsBarColor) ?? fallback.barColor,
      radius: parseCssLength(theme.borderRadius) ?? fallback.radius,
    );
  }

  /// The focused control and the progress bar. Null keeps white focus and the
  /// app's own slider colours.
  final Color? accentColor;

  /// The title, times and unfocused icons.
  final Color textColor;

  /// The audio and subtitle panels.
  final Color panelColor;

  /// The shade behind the transport and progress bar, at the bottom (and,
  /// lighter, at the top).
  final Color barColor;

  /// The corners of track rows and the focused progress bar, in logical
  /// pixels.
  final double radius;

  /// The focused button's disc and the focused track row.
  Color get focusColor => accentColor ?? const Color(0xFFFFFFFF);

  /// Icons and text on [focusColor]: black on a light accent, white on a dark
  /// one.
  Color get onFocusColor => focusColor.computeLuminance() > 0.5
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);

  @override
  bool operator ==(Object other) =>
      other is PlayerControlsTheme &&
      other.accentColor == accentColor &&
      other.textColor == textColor &&
      other.panelColor == panelColor &&
      other.barColor == barColor &&
      other.radius == radius;

  @override
  int get hashCode =>
      Object.hash(accentColor, textColor, panelColor, barColor, radius);
}

/// What a player config asks of the app players, after mapping it to what
/// each route can do. The default is the player's behaviour without a config.
@immutable
final class PlayerOptions {
  const PlayerOptions({
    this.controlsTheme = const PlayerControlsTheme(),
    this.controls = true,
    this.autoHideControls = true,
    this.captions = true,
    this.loop = false,
    this.pictureInPicture = true,
    this.airPlay = true,
    this.ads,
  });

  /// [PlayerConfig.features] and [PlayerConfig.theme] as the app players
  /// read them. Without [applyTheme] the overlay keeps its own look.
  factory PlayerOptions.fromConfig(
    PlayerConfig config, {
    bool applyTheme = true,
  }) {
    final PlayerFeatures f = config.features;
    return PlayerOptions(
      controlsTheme: applyTheme
          ? PlayerControlsTheme.fromPlayerTheme(config.theme)
          : const PlayerControlsTheme(),
      controls: f.controls,
      autoHideControls: f.autoHideControls,
      captions: f.captions,
      loop: f.loop,
      pictureInPicture: f.pip,
      airPlay: f.airplay,
      ads: switch (config.adTagUrl) {
        final String url => PlayerAds(adTagUrl: url),
        null => null,
      },
    );
  }

  /// The TV overlay's look.
  final PlayerControlsTheme controlsTheme;

  /// False hides the TV overlay; the remote's Back still closes the player
  /// and its media keys still play, pause and skip. Phones keep their native
  /// controls, which also hold the Close button.
  final bool controls;

  /// False keeps the TV overlay on screen while playing.
  final bool autoHideControls;

  /// False removes subtitles from the TV overlay and starts without them.
  final bool captions;

  /// Plays again from the start at the end (the native players on Android,
  /// Android TV and iOS; Tizen's player cannot loop).
  final bool loop;

  /// False turns Android's picture-in-picture off.
  final bool pictureInPicture;

  /// False keeps the video off AirPlay on iOS.
  final bool airPlay;

  /// The ads to play (Android, Android TV and iOS), from the config's
  /// `features.ads` and `ads.adTagUrl`. Null plays no ads and makes no ad
  /// request. Compared by identity: one per impression.
  final PlayerAds? ads;

  @override
  bool operator ==(Object other) =>
      other is PlayerOptions &&
      other.controlsTheme == controlsTheme &&
      other.controls == controls &&
      other.autoHideControls == autoHideControls &&
      other.captions == captions &&
      other.loop == loop &&
      other.pictureInPicture == pictureInPicture &&
      other.airPlay == airPlay &&
      identical(other.ads, ads);

  @override
  int get hashCode => Object.hash(
    controlsTheme,
    controls,
    autoHideControls,
    captions,
    loop,
    pictureInPicture,
    airPlay,
    ads,
  );
}

/// A CSS colour as the dashboard stores it: `#rgb`, `#rgba`, `#rrggbb`,
/// `#rrggbbaa`, `rgb(r,g,b)` or `rgba(r,g,b,a)`. Null for anything else.
Color? parseCssColor(String value) {
  final String s = value.trim().toLowerCase();
  if (s.startsWith('#')) {
    String hex = s.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length != 6 && hex.length != 8) return null;
    final int? v = int.tryParse(hex, radix: 16);
    if (v == null) return null;
    return hex.length == 6
        ? Color(0xFF000000 | v)
        // CSS puts alpha last, Flutter first.
        : Color(((v & 0xFF) << 24) | (v >> 8));
  }
  final RegExpMatch? m = RegExp(
    r'^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+%?)\s*)?\)$',
  ).firstMatch(s);
  if (m == null) return null;
  try {
    int channel(String v) => double.parse(v).round().clamp(0, 255);
    double alpha = 1;
    final String? a = m.group(4);
    if (a != null) {
      alpha = a.endsWith('%')
          ? double.parse(a.substring(0, a.length - 1)) / 100
          : double.parse(a);
    }
    return Color.fromARGB(
      (alpha.clamp(0, 1) * 255).round(),
      channel(m.group(1)!),
      channel(m.group(2)!),
      channel(m.group(3)!),
    );
  } on FormatException {
    // `1.2.3` matches the pattern but is no number.
    return null;
  }
}

/// A CSS length in `px` (or a bare number). Null for anything else, e.g.
/// `1rem` or `50%`.
double? parseCssLength(String value) {
  final String s = value.trim().toLowerCase();
  final String number = s.endsWith('px') ? s.substring(0, s.length - 2) : s;
  final double? v = double.tryParse(number.trim());
  return v == null || v < 0 ? null : v;
}
