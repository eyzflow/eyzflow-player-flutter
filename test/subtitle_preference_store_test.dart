import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/src/player/subtitle_preference_store.dart';

void main() {
  tearDown(resetSubtitlePreferenceStore);

  test('starts with no preference', () {
    final store = SubtitlePreferenceStore();
    expect(store.hasPreference, isFalse);
    expect(store.languageCode, isNull);
  });

  test('remember records a language and sets hasPreference', () {
    final store = SubtitlePreferenceStore()..remember('de');
    expect(store.hasPreference, isTrue);
    expect(store.languageCode, 'de');
  });

  test('rememberOff records off as a real preference', () {
    final store = SubtitlePreferenceStore()
      ..remember('de')
      ..rememberOff();
    expect(store.hasPreference, isTrue);
    expect(store.languageCode, isNull);
  });

  test('clear drops any preference', () {
    final store = SubtitlePreferenceStore()
      ..remember('de')
      ..clear();
    expect(store.hasPreference, isFalse);
    expect(store.languageCode, isNull);
  });

  test('setup registers a retrievable singleton; reset clears it', () {
    expect(getSubtitlePreferenceStoreOrNull(), isNull);
    final provided = SubtitlePreferenceStore();
    setupSubtitlePreferenceStore(store: provided);
    expect(getSubtitlePreferenceStoreOrNull(), same(provided));
    resetSubtitlePreferenceStore();
    expect(getSubtitlePreferenceStoreOrNull(), isNull);
  });
}
