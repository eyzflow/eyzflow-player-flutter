import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/hls_renditions.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="de",NAME="Deutsch",DEFAULT=YES,URI="a/de.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="de",NAME="Deutsch AD",CHARACTERISTICS="public.accessibility.describes-video",URI="a/de-ad.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="de",NAME="Deutsch",URI="s/de.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="de",NAME="Deutsch SDH",CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound",URI="s/de-sdh.m3u8"
#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",LANGUAGE="en",NAME="CC",INSTREAM-ID="CC1"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="aud",SUBTITLES="sub"
v/720.m3u8
''';

void main() {
  setUp(() => setEYZFlowPlayerLanguage('de'));
  tearDown(() => setEYZFlowPlayerLanguage(null));

  test('parses AUDIO and SUBTITLES renditions with quoted, comma-bearing '
      'CHARACTERISTICS', () {
    final renditions = parseHlsRenditions(_master);
    expect(renditions.map((r) => r.type), <String>[
      'AUDIO',
      'AUDIO',
      'SUBTITLES',
      'SUBTITLES',
    ]);
    expect(renditions[3].characteristics, <String>{
      hlsTranscribesSpokenDialog,
      hlsDescribesMusicAndSound,
    });
    expect(renditions[3].name, 'Deutsch SDH');
  });

  test(
    'stamps native tracks by language occurrence, across code spellings',
    () async {
      final client = MockClient((_) async => http.Response(_master, 200));
      final result = await annotateHlsTracks(
        Uri.parse('https://example.test/master.m3u8'),
        const <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 0, language: 'deu'),
          PlayerAudioTrack(trackId: 1, language: 'deu'),
        ],
        const <PlayerTextTrack>[
          PlayerTextTrack(trackId: 0, language: 'de'),
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
        client: client,
      );
      expect(result.audio.map((t) => t.isAudioDescription), <bool>[
        false,
        true,
      ]);
      expect(result.text.map((t) => t.isSdh), <bool>[false, true]);
    },
  );

  test('reads CHANNELS from the EYZFlow 5.1 playlist', () async {
    // Verbatim renditions from stream.eyzflow.com/ffa37ff7-…/master.m3u8.
    const master = '''
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="French",LANGUAGE="fr",AUTOSELECT=YES,DEFAULT=YES,CHANNELS="2",URI="audio_1_FRA/main.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="French 5.1 5.1",LANGUAGE="fr",AUTOSELECT=NO,DEFAULT=NO,CHANNELS="6",URI="audio_2_FRA/main.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="atmos",NAME="Atmos",LANGUAGE="fr",CHANNELS="16/JOC",URI="a.m3u8"
''';
    expect(parseHlsRenditions(master).map((r) => r.channels), <int?>[2, 6, 16]);
    final result = await annotateHlsTracks(
      Uri.parse('https://example.test/master.m3u8'),
      const <PlayerAudioTrack>[
        PlayerAudioTrack(trackId: 0, language: 'fr'),
        PlayerAudioTrack(trackId: 1, language: 'fr'),
      ],
      const <PlayerTextTrack>[],
      client: MockClient((_) async => http.Response(master, 200)),
    );
    expect(result.audio.map((t) => t.surroundLabel), <String?>[null, '5.1']);
  });

  test('a failed playlist fetch leaves tracks unlabelled', () async {
    final client = MockClient((_) async => http.Response('', 403));
    final result = await annotateHlsTracks(
      Uri.parse('https://example.test/master.m3u8'),
      const <PlayerAudioTrack>[],
      const <PlayerTextTrack>[PlayerTextTrack(trackId: 0, language: 'de')],
      client: client,
    );
    expect(result.text.single.isSdh, isFalse);
  });

  group('forced subtitles', () {
    const String forcedMaster = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="de",NAME="Deutsch (forced)",FORCED=YES,URI="s/de-forced.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="de",NAME="Deutsch",URI="s/de.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",LANGUAGE="en",NAME="English",URI="s/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="sub"
v/720.m3u8
''';
    MockClient client() =>
        MockClient((_) async => http.Response(forcedMaster, 200));

    test('reads FORCED', () {
      expect(parseHlsRenditions(forcedMaster).map((r) => r.forced), <bool>[
        true,
        false,
        false,
      ]);
    });

    test('a track the native player marks forced is left out', () async {
      final result = await annotateHlsTracks(
        Uri.parse('https://cdn.example/master.m3u8'),
        const <PlayerAudioTrack>[],
        const <PlayerTextTrack>[
          PlayerTextTrack(trackId: 0, language: 'de', forced: true),
          PlayerTextTrack(trackId: 1, language: 'de'),
          PlayerTextTrack(trackId: 2, language: 'en'),
        ],
        client: client(),
      );
      expect(result.text.map((t) => t.trackId), <int>[1, 2]);
      expect(result.forcedText.map((t) => t.trackId), <int>[0]);
      expect(result.forcedText.single.forced, isTrue);
    });

    test('a failed fetch still leaves out a natively forced track', () async {
      final result = await annotateHlsTracks(
        Uri.parse('https://cdn.example/master.m3u8'),
        const <PlayerAudioTrack>[],
        const <PlayerTextTrack>[
          PlayerTextTrack(trackId: 0, language: 'de', forced: true),
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
        client: MockClient((_) async => http.Response('', 403)),
      );
      expect(result.text.map((t) => t.trackId), <int>[1]);
    });

    test('without a native flag (Tizen) the playlist\'s FORCED=YES leaves '
        'the track out', () async {
      final result = await annotateHlsTracks(
        Uri.parse('https://cdn.example/master.m3u8'),
        const <PlayerAudioTrack>[],
        const <PlayerTextTrack>[
          PlayerTextTrack(trackId: 0, language: 'de'),
          PlayerTextTrack(trackId: 1, language: 'de'),
          PlayerTextTrack(trackId: 2, language: 'en'),
        ],
        client: client(),
      );
      expect(result.text.map((t) => t.trackId), <int>[1, 2]);
    });

    test('a player listing fewer tracks than the playlist keeps them all, '
        'rather than drop a real subtitle', () async {
      final result = await annotateHlsTracks(
        Uri.parse('https://cdn.example/master.m3u8'),
        const <PlayerAudioTrack>[],
        const <PlayerTextTrack>[PlayerTextTrack(trackId: 0, language: 'de')],
        client: client(),
      );
      expect(result.text.map((t) => t.trackId), <int>[0]);
    });
  });
}
