import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/system_drm_config.dart';

void main() {
  group('systemDrmConfigForTarget', () {
    test('a trailer never gets a DRM config, even with an access header', () {
      const VideoplayerTarget target = VideoplayerTrailerTarget(
        EyzflowSource(
          id: 'trailer-a',
          title: 'Trailer A',
          drmAccessHeader: 'token',
        ),
      );

      expect(systemDrmConfigForTarget(target, isIOS: false), isNull);
      expect(systemDrmConfigForTarget(target, isIOS: true), isNull);
    });

    test('a source with no access header gets no DRM config', () {
      const VideoplayerTarget target = VideoplayerSourceTarget(
        EyzflowSource(id: 'film-a', title: 'Film A'),
      );

      expect(systemDrmConfigForTarget(target, isIOS: false), isNull);
      expect(systemDrmConfigForTarget(target, isIOS: true), isNull);
    });

    test(
      'an Android source builds a Widevine config with the access header',
      () {
        const VideoplayerTarget target = VideoplayerSourceTarget(
          EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            drmAccessHeader: 'secret-token',
          ),
        );

        final Map<String, dynamic>? config = systemDrmConfigForTarget(
          target,
          isIOS: false,
        );

        expect(config, <String, dynamic>{
          'type': 'widevine',
          'licenseUrl':
              'https://api.eyzflow.com/v1/drm/film-a/widevine/acquire',
          'headers': <String, String>{'access-token': 'secret-token'},
        });
      },
    );

    test(
      'an iOS source builds a FairPlay config with cert and access header',
      () {
        const VideoplayerTarget target = VideoplayerSourceTarget(
          EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            drmAccessHeader: 'secret-token',
          ),
        );

        final Map<String, dynamic>? config = systemDrmConfigForTarget(
          target,
          isIOS: true,
        );

        expect(config, <String, dynamic>{
          'type': 'fairplay',
          'certificateUrl': 'https://stream.eyzflow.com/fps.cer',
          'licenseUrl':
              'https://api.eyzflow.com/v1/drm/film-a/fairplay/acquire',
          'headers': <String, String>{'access-token': 'secret-token'},
        });
      },
    );
  });
}
