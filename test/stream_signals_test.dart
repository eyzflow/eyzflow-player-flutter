import 'package:eyzflow_player/src/signals/stream_signals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

/// A media playlist as the backend writes it (manifest-signal-markers.util.ts).
const String _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-TARGETDURATION:6
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-MAP:URI="init.mp4"
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="eyz-recap",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:02.000Z",DURATION=10.000,X-EYZ-TYPE="recap"
#EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:15.000Z",DURATION=15.000,X-EYZ-TYPE="intro",X-EYZ-LABEL="Main titles"
#EXT-X-DATERANGE:ID="eyz-ad-1",START-DATE="1970-01-01T00:00:40.000Z",PLANNED-DURATION=30.000,SCTE35-OUT=0xFC302000
#EXT-X-DATERANGE:ID="eyz-closing-credits",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:50.000Z",DURATION=10.000,X-EYZ-TYPE="closing_credits"
#EXTINF:6.000,
seg-1.m4s
#EXT-X-ENDLIST
''';

const String _master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
video/360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
video/720p.m3u8
''';

void main() {
  group('parseHlsSignals', () {
    test('reads the backend DATERANGEs: type, span and label', () {
      expect(parseHlsSignals(_mediaPlaylist), <StreamSignal>[
        StreamSignal(
          id: 'eyz-recap',
          type: StreamSignalType.recap,
          start: _s(2),
          end: _s(12),
        ),
        StreamSignal(
          id: 'eyz-intro',
          type: StreamSignalType.intro,
          start: _s(15),
          end: _s(30),
          label: 'Main titles',
        ),
        StreamSignal(
          id: 'eyz-closing-credits',
          type: StreamSignalType.closingCredits,
          start: _s(50),
          end: _s(60),
        ),
      ]);
    });

    test('takes END-DATE when there is no DURATION', () {
      const String playlist = '''
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",END-DATE="1970-01-01T00:01:05.000Z",X-EYZ-TYPE="opening_credits"
''';
      expect(parseHlsSignals(playlist).single.end, _s(65));
    });

    test('skips ad breaks, unknown types, empty spans and an unanchored '
        'playlist', () {
      const String noAnchor = '''
#EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="intro"
''';
      const String odd = '''
#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z
#EXT-X-DATERANGE:ID="a",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="ad_break"
#EXT-X-DATERANGE:ID="b",CLASS="com.eyzflow.signal",START-DATE="1970-01-01T00:00:05.000Z",DURATION=0,X-EYZ-TYPE="intro"
#EXT-X-DATERANGE:ID="c",CLASS="com.example.other",START-DATE="1970-01-01T00:00:05.000Z",DURATION=60,X-EYZ-TYPE="intro"
''';
      expect(parseHlsSignals(noAnchor), isEmpty);
      expect(parseHlsSignals(odd), isEmpty);
    });
  });

  test('parseDashSignals reads the backend EventStream', () {
    const String mpd = '''
<MPD><Period id="0">
    <EventStream schemeIdUri="urn:scte:scte35:2014:xml+bin" timescale="1000">
      <Event presentationTime="40000" duration="30000" id="1"><scte35:Signal/></Event>
    </EventStream>
    <EventStream schemeIdUri="urn:eyzflow:signal" value="1" timescale="1000">
      <Event presentationTime="2000" duration="10000" id="1" messageData="recap"/>
      <Event presentationTime="15000" duration="15000" id="2" messageData="intro:Main titles"/>
      <Event presentationTime="20000" duration="0" id="3" messageData="intro"/>
    </EventStream>
    <AdaptationSet/>
</Period></MPD>
''';
    expect(parseDashSignals(mpd), <StreamSignal>[
      StreamSignal(
        id: 'recap-1',
        type: StreamSignalType.recap,
        start: _s(2),
        end: _s(12),
      ),
      StreamSignal(
        id: 'intro-2',
        type: StreamSignalType.intro,
        start: _s(15),
        end: _s(30),
        label: 'Main titles',
      ),
    ]);
  });

  group('loadHlsMarkers', () {
    test('reads ad breaks and signals from the first media playlist', () async {
      final List<Uri> fetched = <Uri>[];
      final MockClient client = MockClient((http.Request request) async {
        fetched.add(request.url);
        return http.Response(
          request.url.path.endsWith('master.m3u8') ? _master : _mediaPlaylist,
          200,
        );
      });
      final HlsMarkers markers = await loadHlsMarkers(
        client,
        Uri.parse('https://stream.example.com/film/master.m3u8'),
      );
      expect(fetched.map((Uri u) => u.path), <String>[
        '/film/master.m3u8',
        '/film/video/360p.m3u8',
      ]);
      expect(markers.adBreaks.single.start, _s(40));
      expect(
        markers.signals.map((StreamSignal s) => s.type),
        <StreamSignalType>[
          StreamSignalType.recap,
          StreamSignalType.intro,
          StreamSignalType.closingCredits,
        ],
      );
    });

    test('gives none when the manifest cannot be read', () async {
      final MockClient client = MockClient(
        (http.Request request) async => throw http.ClientException('offline'),
      );
      final HlsMarkers markers = await loadHlsMarkers(
        client,
        Uri.parse('https://stream.example.com/film/master.m3u8'),
      );
      expect(markers.adBreaks, isEmpty);
      expect(markers.signals, isEmpty);
    });
  });

  group('signalAt', () {
    final List<StreamSignal> signals = <StreamSignal>[
      StreamSignal(
        id: 'credits',
        type: StreamSignalType.openingCredits,
        start: _s(0),
        end: _s(120),
      ),
      StreamSignal(
        id: 'intro',
        type: StreamSignalType.intro,
        start: _s(30),
        end: _s(90),
      ),
    ];

    test('is in a span from its start until just before its end', () {
      final List<StreamSignal> intro = <StreamSignal>[signals[1]];
      expect(signalAt(intro, _s(29.9)), isNull);
      expect(signalAt(intro, _s(30))?.id, 'intro');
      expect(signalAt(intro, _s(89.7))?.id, 'intro');
      expect(signalAt(intro, _s(89.8)), isNull);
      expect(signalAt(intro, _s(90)), isNull);
      expect(signalAt(intro, null), isNull);
    });

    test('picks the span that started last when two overlap', () {
      expect(signalAt(signals, _s(10))?.id, 'credits');
      expect(signalAt(signals, _s(40))?.id, 'intro');
      expect(signalAt(signals, _s(100))?.id, 'credits');
    });
  });

  test('SignalTracker reports entering and leaving, the old one first', () {
    final List<String> log = <String>[];
    final SignalTracker tracker = SignalTracker(
      onStarted: (StreamSignal s) => log.add('start ${s.id}'),
      onEnded: (StreamSignal s) => log.add('end ${s.id}'),
    );
    tracker.position(_s(20));
    expect(log, isEmpty, reason: 'no signals read yet');
    tracker.signals = parseHlsSignals(_mediaPlaylist);
    tracker
      ..position(_s(21))
      ..position(_s(5))
      ..position(_s(6))
      ..position(_s(55))
      ..position(null);
    expect(log, <String>[
      'start eyz-intro',
      'end eyz-intro',
      'start eyz-recap',
      'end eyz-recap',
      'start eyz-closing-credits',
      'end eyz-closing-credits',
    ]);
    expect(tracker.value, isNull);
    tracker.dispose();
  });

  test('SignalTracker: a skip stays done while stale positions come in', () {
    final List<String> log = <String>[];
    final SignalTracker tracker = SignalTracker(
      onStarted: (StreamSignal s) => log.add('start ${s.id}'),
      onEnded: (StreamSignal s) => log.add('end ${s.id}'),
    )..signals = parseHlsSignals(_mediaPlaylist);
    tracker.position(_s(20));
    final StreamSignal intro = tracker.value!;
    tracker.skipped(intro, _s(30));
    expect(tracker.value, isNull);
    // The native player still reports where it was until the seek lands.
    tracker
      ..position(_s(20.5))
      ..position(_s(21));
    expect(tracker.value, isNull);
    // Landed: playing on past the intro.
    tracker
      ..position(_s(30))
      ..position(_s(30.5));
    expect(tracker.value, isNull);
    // Seeking back into it later shows it again.
    tracker.position(_s(16));
    expect(tracker.value?.id, 'eyz-intro');
    expect(log, <String>[
      'start eyz-intro',
      'end eyz-intro',
      'start eyz-intro',
    ]);
    tracker.dispose();
  });

  test('SignalTracker: Tizen reports the target, then the old position, '
      'before the seek lands', () {
    final SignalTracker tracker = SignalTracker()
      ..signals = parseHlsSignals(_mediaPlaylist)
      ..position(_s(20));
    tracker.skipped(tracker.value!, _s(30));
    // AVPlay sets its position to the target when seekTo returns …
    tracker.position(_s(30));
    expect(tracker.value, isNull);
    // … then polls PlusPlayer, which still plays the intro for a few seconds.
    for (final double s in <double>[20.5, 21, 21.5, 22, 22.5]) {
      tracker.position(_s(s));
      expect(tracker.value, isNull, reason: 'stale $s s');
    }
    // Landed.
    tracker
      ..position(_s(30.1))
      ..position(_s(30.6));
    expect(tracker.value, isNull);
    // Seeking back into it later shows it again.
    tracker.position(_s(16));
    expect(tracker.value?.id, 'eyz-intro');
    tracker.dispose();
  });

  test(
    'SignalTracker: seeking back before a skipped signal clears the skip',
    () {
      final SignalTracker tracker = SignalTracker()
        ..signals = parseHlsSignals(_mediaPlaylist)
        ..position(_s(20));
      tracker.skipped(tracker.value!, _s(30));
      tracker
        ..position(_s(1))
        ..position(_s(15));
      expect(tracker.value?.id, 'eyz-intro');
      tracker.dispose();
    },
  );

  test('SignalTracker: Android reports the target, then lands on an earlier '
      'keyframe inside the signal', () {
    final SignalTracker tracker = SignalTracker()
      ..signals = parseHlsSignals(_mediaPlaylist)
      ..position(_s(20));
    tracker.skipped(tracker.value!, _s(30));
    // ExoPlayer reports the requested position while it seeks …
    tracker
      ..position(_s(30))
      ..position(_s(30))
      ..position(_s(30));
    expect(tracker.value, isNull);
    // … then the keyframe it snapped to, 2 s before the intro's end.
    for (final double s in <double>[28, 28.5, 29, 29.5, 30.5, 31]) {
      tracker.position(_s(s));
      expect(tracker.value, isNull, reason: 'landed early, $s s');
    }
    tracker.dispose();
  });

  test('SignalTracker: only a seek elsewhere ends a skip', () {
    final SignalTracker tracker = SignalTracker()
      ..signals = parseHlsSignals(_mediaPlaylist)
      ..position(_s(20));
    tracker
      ..skipped(tracker.value!, _s(30))
      // The skip's own seek.
      ..seeked(_s(30))
      ..position(_s(28));
    expect(tracker.value, isNull);
    tracker
      ..seeked(_s(18))
      ..position(_s(18));
    expect(tracker.value?.id, 'eyz-intro');
    tracker.dispose();
  });
}
