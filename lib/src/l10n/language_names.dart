import 'generated_language_names.dart';
import 'player_language.dart';

/// Codes that name no determinate language: unknown, undetermined, no
/// linguistic content. Tracks with them get no name of their own.
const Set<String> undeterminedLanguageCodes = <String>{'un', 'und', 'zxx'};

/// Resolves a language code to a name; return null to fall back to the
/// player's own table.
typedef LanguageNameResolver = String? Function(String code, String uiLanguage);

/// Names for the languages of audio and subtitle tracks, in the player's UI
/// language ([eyzflowPlayerLanguage]): "Deutsch" for `de`, `deu`, `ger` or
/// `de_DE` when the player shows German.
///
/// Built in, from the Unicode CLDR display names, for the player's four UI
/// languages; an app with its own names sets [resolver].
abstract final class EYZFlowLanguageNames {
  /// Cast senders and receivers can use different tags for the same language.
  static bool sameBaseLanguage(String? first, String? second) {
    String? name(String? code) =>
        code == null ? null : languageName(code.split(RegExp('[-_]')).first);
    final wanted = name(first);
    return wanted != null && wanted == name(second);
  }

  /// Consulted first; null (the default) uses the built-in table only.
  static LanguageNameResolver? resolver;

  static final Map<String, String> _englishNameToCode = <String, String>{
    for (final MapEntry(:key, :value) in generatedLanguageNames['en']!.entries)
      value.toLowerCase(): key,
  };

  /// The name for [code], or null when it is blank or names no determinate
  /// language (see [undeterminedLanguageCodes]).
  ///
  /// Resolution order: the exact code, the code without its region
  /// (`pt_BR` → `pt`), the ISO 639-1 code a three-letter code stands for
  /// (`eng` → `en`), an English language name (`French` → `fr`), and finally
  /// the input itself, so the result is never empty.
  static String? languageName(String code, {String? uiLanguage}) {
    final String trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    final String key = trimmed.replaceAll('-', '_');
    final String base = key.split('_').first;
    final String lowerBase = base.toLowerCase();
    if (undeterminedLanguageCodes.contains(lowerBase)) return null;

    final String language = uiLanguage ?? eyzflowPlayerLanguage;
    final String? custom = resolver?.call(trimmed, language);
    if (custom != null && custom.isNotEmpty) return custom;

    final Map<String, String> names =
        generatedLanguageNames[language] ?? generatedLanguageNames['en']!;
    final String? alias = generatedIsoAliases[lowerBase];
    final String? fromEnglishName = _englishNameToCode[trimmed.toLowerCase()];
    return names[key] ??
        names[base] ??
        names[lowerBase] ??
        (alias == null ? null : names[alias]) ??
        (fromEnglishName == null ? null : names[fromEnglishName]) ??
        trimmed;
  }
}
