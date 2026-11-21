import 'package:get_it/get_it.dart';

/// Package-owned locator, kept separate from any app-wide `GetIt.instance` so
/// `eyzflow_player` never depends on the app's locator.
final GetIt _subtitleLocator = GetIt.asNewInstance();

/// Remembers the viewer's most recent subtitle language for the app-process
/// lifetime — across films within one session. Deliberately not persisted
/// across app restarts.
///
/// A `null` [languageCode] with [hasPreference] true means the viewer turned
/// subtitles off, and the next film starts off too. When a remembered
/// language has no matching text track on the next film, the controls select
/// nothing (product decision).
final class SubtitlePreferenceStore {
  SubtitlePreferenceStore();

  bool get hasPreference => _hasPreference;
  String? get languageCode => _languageCode;

  bool _hasPreference = false;
  String? _languageCode;

  void remember(String languageCode) {
    _hasPreference = true;
    _languageCode = languageCode;
  }

  void rememberOff() {
    _hasPreference = true;
    _languageCode = null;
  }

  void clear() {
    _hasPreference = false;
    _languageCode = null;
  }
}

/// Registers the app-session store. Idempotent.
void setupSubtitlePreferenceStore({SubtitlePreferenceStore? store}) {
  if (_subtitleLocator.isRegistered<SubtitlePreferenceStore>()) {
    _subtitleLocator.unregister<SubtitlePreferenceStore>();
  }
  _subtitleLocator.registerLazySingleton<SubtitlePreferenceStore>(
    () => store ?? SubtitlePreferenceStore(),
  );
}

/// The registered store, or `null` when composition never registered one.
SubtitlePreferenceStore? getSubtitlePreferenceStoreOrNull() =>
    _subtitleLocator.isRegistered<SubtitlePreferenceStore>()
    ? _subtitleLocator<SubtitlePreferenceStore>()
    : null;

/// Test helper, matching the `tizen_device_diagnostics.dart` convention.
void resetSubtitlePreferenceStore() {
  if (_subtitleLocator.isRegistered<SubtitlePreferenceStore>()) {
    _subtitleLocator.unregister<SubtitlePreferenceStore>();
  }
}
