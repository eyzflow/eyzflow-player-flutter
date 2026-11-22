import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    setEYZFlowPlayerLanguage(null);
    EYZFlowLanguageNames.resolver = null;
  });

  String? name(String code) => EYZFlowLanguageNames.languageName(code);

  group('EYZFlowLanguageNames', () {
    test('resolves two-letter, three-letter and regional codes', () {
      setEYZFlowPlayerLanguage('de');
      // Two-letter, terminological and bibliographic three-letter codes.
      expect(name('de'), 'Deutsch');
      expect(name('deu'), 'Deutsch');
      expect(name('ger'), 'Deutsch');
      // A region the table has, and one it falls back from.
      expect(name('en_GB'), 'Britisches Englisch');
      expect(name('de-DE'), 'Deutsch');
      // Case does not matter for the base.
      expect(name('FRA'), 'Französisch');
    });

    test('names in the player language', () {
      setEYZFlowPlayerLanguage('en');
      expect(name('nld'), 'Dutch');
      setEYZFlowPlayerLanguage('fr');
      expect(name('nld'), 'néerlandais');
      setEYZFlowPlayerLanguage('nl');
      expect(name('nld'), 'Nederlands');
      expect(
        EYZFlowLanguageNames.languageName('nld', uiLanguage: 'de'),
        'Niederländisch',
      );
    });

    test('reads an English language name', () {
      setEYZFlowPlayerLanguage('de');
      expect(name('French'), 'Französisch');
    });

    test('undetermined and blank codes have no name', () {
      for (final code in ['und', 'zxx', 'un', '', '  ']) {
        expect(name(code), isNull, reason: code);
      }
    });

    test('an unknown code is shown as it is', () {
      expect(name('xyz'), 'xyz');
    });

    test('an app resolver goes first, and falls back to the table', () {
      setEYZFlowPlayerLanguage('de');
      EYZFlowLanguageNames.resolver = (code, ui) =>
          code == 'de' ? 'Deutsch ($ui, app)' : null;
      expect(name('de'), 'Deutsch (de, app)');
      expect(name('en'), 'Englisch');
    });
  });

  group('eyzflowPlayerLanguage', () {
    test('a language the player has is kept', () {
      setEYZFlowPlayerLanguage('nl_BE');
      expect(eyzflowPlayerLanguage, 'nl');
    });

    test('a language the player does not have falls back to English', () {
      setEYZFlowPlayerLanguage('ja');
      expect(eyzflowPlayerLanguage, 'en');
    });

    test('unset, it follows the device', () {
      setEYZFlowPlayerLanguage(null);
      // The test binding reports en_US.
      expect(eyzflowPlayerLanguage, 'en');
    });
  });

  test('the source derives the stream and DRM URLs from its id', () {
    const source = EYZFlowSource(
      id: 's1',
      title: 'Film',
      sourceType: EYZFlowFilm('cat-1'),
    );
    expect(
      source.hlsStreamUrl.toString(),
      'https://stream.eyzflow.com/s1/master.m3u8',
    );
    expect(
      source.dashStreamUrl.toString(),
      'https://stream.eyzflow.com/s1/manifest.mpd',
    );
    expect(
      source.fairplayCertificateUrl.toString(),
      'https://stream.eyzflow.com/fps.cer',
    );
    expect(
      source.fairplayLicenseUrl.toString(),
      'https://api.eyzflow.com/v1/drm/s1/fairplay/acquire',
    );
    expect(
      source.widevineLicenseUrl.toString(),
      'https://api.eyzflow.com/v1/drm/s1/widevine/acquire',
    );
    expect(
      source.thumbnailsUrl.toString(),
      'https://stream.eyzflow.com/s1/thumbnails/thumbnail.vtt',
    );
    expect(
      source.copyWith(progressSeconds: 30),
      const EYZFlowSource(
        id: 's1',
        title: 'Film',
        sourceType: EYZFlowFilm('cat-1'),
        progressSeconds: 30,
      ),
    );
    expect(const EYZFlowFilm('a'), isNot(const EYZFlowTrailer('a')));
  });
}
