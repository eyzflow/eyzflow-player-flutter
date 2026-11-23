import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/signals/stream_signals.dart'
    show loadHlsMarkers;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A media playlist as the backend writes it
/// (`manifest-signal-markers.util.ts`): an ad break at 0 s, one at 8 s with
/// a planned pod of 30 s, and an intro span that is no ad break.
const String _mediaPlaylist = '''#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="eyz-ad-1",START-DATE="1970-01-01T00:00:00.000Z",SCTE35-OUT=0xFC302000000000000000FFF00F05000000017FEF7E0000000000000000000000
#EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:02.000Z",DURATION=20.000,X-EYZ-TYPE="intro",X-EYZ-LABEL="Intro, part 1"
#EXT-X-DATERANGE:ID="eyz-ad-2",START-DATE="1970-01-01T00:00:08.000Z",PLANNED-DURATION=30.000,SCTE35-OUT=0xFC302500000000000000FFF01405000000027FEFFE000AFC80FE0029325E0000000000000000
#EXTINF:6.000,
seg-0.ts
#EXTINF:6.000,
seg-1.ts
#EXT-X-ENDLIST
''';

const String _masterPlaylist = '''#EXTM3U
#EXT-X-VERSION:6
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Deutsch",LANGUAGE="de",URI="audio/de/index.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs/en/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aud"

video/720p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aud"
video/1080p/index.m3u8
''';

const String _mpd = '''<?xml version="1.0" encoding="utf-8"?>
<MPD xmlns:scte35="http://www.scte.org/schemas/35/2016" xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period id="0" start="PT0S">
    <EventStream schemeIdUri="urn:scte:scte35:2014:xml+bin" timescale="1000">
      <Event presentationTime="0" id="1"><scte35:Signal><scte35:Binary>/DAgAAAAAAAAAP/wDwUAAAABf+9+AAAAAAAAAAAAAAA=</scte35:Binary></scte35:Signal></Event>
      <Event presentationTime="8000" duration="30000" id="2"><scte35:Signal><scte35:Binary>/DAlAAAAAAAAAP/wFAUAAAACf+/+AAr8gP4AKTJeAAAAAAAAAAA=</scte35:Binary></scte35:Signal></Event>
    </EventStream>
    <EventStream schemeIdUri="urn:eyzflow:signal" value="1" timescale="1000">
      <Event presentationTime="2000" duration="20000" id="1" messageData="intro"/>
    </EventStream>
    <AdaptationSet mimeType="video/mp4"></AdaptationSet>
  </Period>
</MPD>
''';

void main() {
  group('HLS markers', () {
    test('reads the ad breaks and skips the intro and credits spans', () {
      expect(parseHlsAdBreaks(_mediaPlaylist), const <AdBreak>[
        AdBreak(id: 'eyz-ad-1', start: Duration.zero),
        AdBreak(
          id: 'eyz-ad-2',
          start: Duration(seconds: 8),
          duration: Duration(seconds: 30),
        ),
      ]);
    });

    test('START-DATE is placed against the playlist anchor', () {
      const String playlist = '''#EXTM3U
#EXT-X-PROGRAM-DATE-TIME:2026-01-01T10:00:00.000Z
#EXT-X-DATERANGE:ID="b",START-DATE="2026-01-01T10:01:30.500Z",SCTE35-OUT=0xFC
#EXTINF:6.000,
seg-0.ts
''';
      expect(
        parseHlsAdBreaks(playlist).single.start,
        const Duration(seconds: 90, milliseconds: 500),
      );
    });

    test('without an anchor no DATERANGE can be placed', () {
      expect(
        parseHlsAdBreaks(
          '#EXTM3U\n#EXT-X-DATERANGE:ID="a",START-DATE='
          '"1970-01-01T00:00:08.000Z",SCTE35-OUT=0xFC\n',
        ),
        isEmpty,
      );
    });

    test('a playlist without markers has no breaks', () {
      expect(parseHlsAdBreaks('#EXTM3U\n#EXTINF:6.0,\nseg.ts\n'), isEmpty);
    });

    test('media playlists come from the master, video first', () {
      expect(
        hlsMediaPlaylistUris(
          _masterPlaylist,
          Uri.parse('https://stream.eyzflow.com/s1/master.m3u8'),
        ),
        <Uri>[
          Uri.parse('https://stream.eyzflow.com/s1/video/720p/index.m3u8'),
          Uri.parse('https://stream.eyzflow.com/s1/video/1080p/index.m3u8'),
          Uri.parse('https://stream.eyzflow.com/s1/audio/de/index.m3u8'),
        ],
      );
    });

    test('loads the master, then its first media playlist', () async {
      final List<Uri> fetched = <Uri>[];
      final MockClient client = MockClient((http.Request request) async {
        fetched.add(request.url);
        return switch (request.url.path) {
          '/s1/master.m3u8' => http.Response(_masterPlaylist, 200),
          '/s1/video/720p/index.m3u8' => http.Response(_mediaPlaylist, 200),
          _ => http.Response('', 404),
        };
      });
      final List<AdBreak> breaks = (await loadHlsMarkers(
        client,
        Uri.parse('https://stream.eyzflow.com/s1/master.m3u8'),
      )).adBreaks;
      expect(breaks.map((AdBreak b) => b.start), const <Duration>[
        Duration.zero,
        Duration(seconds: 8),
      ]);
      expect(fetched, hasLength(2));
    });

    test('a manifest that cannot be loaded gives no breaks', () async {
      final MockClient failing = MockClient(
        (http.Request request) async => throw http.ClientException('offline'),
      );
      expect(
        (await loadHlsMarkers(
          failing,
          Uri.parse('https://stream.eyzflow.com/s1/master.m3u8'),
        )).adBreaks,
        isEmpty,
      );
      final MockClient missing = MockClient(
        (http.Request request) async => http.Response('', 403),
      );
      expect(
        (await loadHlsMarkers(
          missing,
          Uri.parse('https://stream.eyzflow.com/s1/master.m3u8'),
        )).adBreaks,
        isEmpty,
      );
    });
  });

  group('DASH markers', () {
    test('reads the SCTE-35 events and skips the EYZFlow signals', () {
      expect(parseDashAdBreaks(_mpd), const <AdBreak>[
        AdBreak(id: '1', start: Duration.zero),
        AdBreak(
          id: '2',
          start: Duration(seconds: 8),
          duration: Duration(seconds: 30),
        ),
      ]);
    });

    test('presentationTime is in the stream timescale', () {
      const String mpd =
          '<MPD><Period><EventStream schemeIdUri="urn:scte:scte35:2013:xml" '
          'timescale="90000"><Event presentationTime="1350000" id="9"/>'
          '</EventStream></Period></MPD>';
      expect(parseDashAdBreaks(mpd).single.start, const Duration(seconds: 15));
    });

    test('an MPD without markers has no breaks', () {
      expect(parseDashAdBreaks('<MPD><Period></Period></MPD>'), isEmpty);
    });
  });

  group('schedule', () {
    AdBreakSchedule schedule(List<int> seconds) => AdBreakSchedule(<AdBreak>[
      for (final int s in seconds)
        AdBreak(
          id: 'b$s',
          start: Duration(seconds: s),
        ),
    ]);

    test('a break at the start is the pre-roll, taken once', () {
      final AdBreakSchedule breaks = schedule(<int>[0, 8]);
      expect(breaks.takePreroll()?.id, 'b0');
      expect(breaks.takePreroll(), isNull);
    });

    test('no pre-roll without a break at the start', () {
      expect(schedule(<int>[8]).takePreroll(), isNull);
    });

    test('a mid-roll is due when playback reaches it, once', () {
      final AdBreakSchedule breaks = schedule(<int>[8]);
      const Duration at7500 = Duration(milliseconds: 7500);
      const Duration at8000 = Duration(seconds: 8);
      expect(breaks.due(Duration.zero, at7500), isNull);
      expect(breaks.due(at7500, at8000)?.id, 'b8');
      // Rewinding and playing through it again plays nothing.
      expect(breaks.due(at7500, at8000), isNull);
    });

    test('a break passed by seeking is not played', () {
      final AdBreakSchedule breaks = schedule(<int>[8]);
      expect(
        breaks.due(const Duration(seconds: 4), const Duration(seconds: 20)),
        isNull,
      );
      expect(
        breaks.due(const Duration(seconds: 20), const Duration(seconds: 6)),
        isNull,
      );
    });

    test('the pre-roll is never a mid-roll', () {
      final AdBreakSchedule breaks = schedule(<int>[0]);
      expect(breaks.due(Duration.zero, const Duration(seconds: 1)), isNull);
    });
  });
}
