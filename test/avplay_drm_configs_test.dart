import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:video_player_avplay/video_player.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';
import 'package:eyzflow_player/src/player/widevine_license_client.dart';

const EyzflowSource _trailerSource = EyzflowSource(
  id: 'trailer-a',
  title: 'Trailer A',
);
const VideoplayerTarget _trailerA = VideoplayerTrailerTarget(_trailerSource);

void main() {
  test('a trailer target passes no DRM configuration', () {
    expect(drmConfigsForTarget(_trailerA, WidevineLicenseClient()), isNull);
  });

  test('a trailer target is never DRM-protected, even if its source carries a '
      'feature-length sourceType', () {
    const EyzflowSource source = EyzflowSource(
      id: 'trailer-with-drm-shaped-source',
      title: 'Trailer',
      drmAccessHeader: 'base64-drm-payload',
      sourceType: EyzflowFilm('title-a'),
    );

    expect(
      drmConfigsForTarget(
        VideoplayerTrailerTarget(source),
        WidevineLicenseClient(),
      ),
      isNull,
    );
  });

  test(
    'a source DRM payload configures its own Widevine licence request',
    () async {
      const EyzflowSource source = EyzflowSource(
        id: 'film-a',
        title: 'Film A',
        drmAccessHeader: 'base64-drm-payload',
        sourceType: EyzflowFilm('title-a'),
      );
      final WidevineLicenseClient client = WidevineLicenseClient(
        httpClient: MockClient((http.Request request) async {
          expect(request.url, source.widevineLicenseUrl);
          expect(request.headers['access-token'], 'base64-drm-payload');
          return http.Response.bytes(<int>[4, 5, 6], 200);
        }),
      );
      final DrmConfigs configs = drmConfigsForTarget(
        VideoplayerSourceTarget(source),
        client,
      )!;

      expect(
        await configs.licenseCallback!(Uint8List.fromList(<int>[1])),
        <int>[4, 5, 6],
      );
    },
  );

  // Every target resolves to the HLS master playlist, proven on hardware where
  // the DASH path never played a film. Widevine rides on HLS here: the
  // playlists carry an inline pssh, and FairPlay is not even expressible —
  // `DrmType` offers only none, playready, and widevine.
  test('a target resolves to an HLS master playlist URL', () {
    expect(
      _trailerSource.hlsStreamUrl.toString(),
      endsWith('/trailer-a/master.m3u8'),
    );
  });

  test('a DRM-carrying source selects Widevine and only Widevine', () {
    const EyzflowSource source = EyzflowSource(
      id: 'film-a',
      title: 'Film A',
      drmAccessHeader: 'base64-drm-payload',
      sourceType: EyzflowFilm('title-a'),
    );
    final DrmConfigs? configs = drmConfigsForTarget(
      const VideoplayerSourceTarget(source),
      WidevineLicenseClient(),
    );

    expect(configs, isNotNull);
    expect(configs!.type, DrmType.widevine);
    expect(configs.licenseCallback, isNotNull);
    // The application must never delegate to a licence server URL, and must
    // never select PlayReady.
    expect(configs.licenseServerUrl, isNull);
    expect(configs.type, isNot(DrmType.playready));
  });
}
