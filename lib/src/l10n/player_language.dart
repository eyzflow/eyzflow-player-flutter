import 'dart:ui' show PlatformDispatcher;

/// The languages the player's own text comes in.
const List<String> eyzflowPlayerLanguages = <String>['en', 'de', 'fr', 'nl'];

String? _language;

/// The language of the player's own text (controls, errors, track names),
/// as a language code: the one set with [setEyzflowPlayerLanguage], else the
/// device's language when the player has it, else English.
String get eyzflowPlayerLanguage =>
    _language ?? _supported(PlatformDispatcher.instance.locale.languageCode);

/// Sets the language of the player's own text, e.g. to the storefront's or
/// the app's language; `null` follows the device again. A language the
/// player does not have falls back to English.
///
/// `EyzflowPlayer(language:)` sets it for one player; call this when using
/// `VideoplayerFeatureView` directly.
void setEyzflowPlayerLanguage(String? languageCode) {
  _language = languageCode == null ? null : _supported(languageCode);
}

String _supported(String code) {
  final String base = code.split(RegExp('[-_]')).first.toLowerCase();
  return eyzflowPlayerLanguages.contains(base) ? base : 'en';
}
