import 'package:eyzflow_player/src/ads/vast.dart';
import 'package:eyzflow_player/src/ads/vast_loader.dart';
import 'package:flutter_test/flutter_test.dart';

const String _inline = '''
<?xml version="1.0" encoding="UTF-8"?>
<VAST version="4.1">
  <Error><![CDATA[https://ads.example/no-ad?e=[ERRORCODE]]]></Error>
  <Ad id="a1">
    <InLine>
      <AdSystem>Test</AdSystem>
      <AdTitle>Spot</AdTitle>
      <Impression><![CDATA[ https://ads.example/imp ]]></Impression>
      <Error>https://ads.example/err?code=[ERRORCODE]</Error>
      <Creatives>
        <Creative>
          <CompanionAds/>
        </Creative>
        <Creative sequence="1">
          <Linear skipoffset="00:00:05">
            <Duration>00:00:15.500</Duration>
            <TrackingEvents>
              <Tracking event="start">https://ads.example/start</Tracking>
              <Tracking event="progress" offset="00:00:10">https://ads.example/p10</Tracking>
              <Tracking event="complete">https://ads.example/complete</Tracking>
            </TrackingEvents>
            <VideoClicks>
              <ClickThrough>https://brand.example</ClickThrough>
              <ClickTracking>https://ads.example/click</ClickTracking>
            </VideoClicks>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4" width="1280" height="720" bitrate="2000">
                <![CDATA[https://cdn.example/720.mp4]]>
              </MediaFile>
              <MediaFile delivery="progressive" type="video/mp4" width="1920" height="1080" bitrate="5000">
                https://cdn.example/1080.mp4
              </MediaFile>
              <MediaFile delivery="progressive" type="application/javascript" apiFramework="VPAID">
                https://cdn.example/vpaid.js
              </MediaFile>
            </MediaFiles>
          </Linear>
        </Creative>
      </Creatives>
    </InLine>
  </Ad>
</VAST>
''';

void main() {
  group('parseAdTag', () {
    test('reads an inline linear ad', () {
      final AdTagResponse response = parseAdTag(_inline);
      expect(response, isA<VastTagResponse>());
      final VastResponse vast = (response as VastTagResponse).vast;
      expect(vast.version, '4.1');
      expect(vast.errors.single.toString(), contains('no-ad'));
      final VastAd ad = vast.ads.single;
      expect(ad.id, 'a1');
      expect(ad.isWrapper, isFalse);
      expect(ad.impressions.single, Uri.parse('https://ads.example/imp'));
      final VastLinear linear = ad.linear!;
      expect(linear.duration, const Duration(seconds: 15, milliseconds: 500));
      expect(linear.skipOffset, const VastTimeOffset(Duration(seconds: 5)));
      expect(linear.mediaFiles, hasLength(3));
      expect(linear.mediaFiles.first.height, 720);
      expect(linear.tracking.map((VastTracking t) => t.event), <String>[
        'start',
        'progress',
        'complete',
      ]);
      expect(
        linear.tracking[1].offset,
        const VastTimeOffset(Duration(seconds: 10)),
      );
      expect(linear.clickThrough, Uri.parse('https://brand.example'));
    });

    test('reads a wrapper', () {
      final VastResponse vast = parseVast('''
<VAST version="3.0"><Ad id="w" sequence="2"><Wrapper followAdditionalWrappers="false">
  <VASTAdTagURI><![CDATA[https://ads.example/next.xml]]></VASTAdTagURI>
  <Impression>https://ads.example/wimp</Impression>
  <Creatives><Creative><Linear><TrackingEvents>
    <Tracking event="firstQuartile">https://ads.example/wq1</Tracking>
  </TrackingEvents></Linear></Creative></Creatives>
</Wrapper></Ad></VAST>''');
      final VastAd ad = vast.ads.single;
      expect(ad.isWrapper, isTrue);
      expect(ad.sequence, 2);
      expect(ad.wrapperTagUri, Uri.parse('https://ads.example/next.xml'));
      expect(ad.followAdditionalWrappers, isFalse);
      expect(ad.wrapperTracking.single.event, 'firstQuartile');
    });

    test('reads a VMAP with its prefix, offsets and inline VAST', () {
      final AdTagResponse response = parseAdTag(
        '''
<vmap:VMAP xmlns:vmap="http://www.iab.net/videosuite/vmap" version="1.0">
  <vmap:AdBreak timeOffset="start" breakType="linear" breakId="pre">
    <vmap:AdSource><vmap:AdTagURI templateType="vast3"><![CDATA[https://ads.example/pre]]></vmap:AdTagURI></vmap:AdSource>
  </vmap:AdBreak>
  <vmap:AdBreak timeOffset="00:00:15.000" breakType="linear" breakId="mid">
    <vmap:AdSource><vmap:VASTAdData>$_inline</vmap:VASTAdData></vmap:AdSource>
  </vmap:AdBreak>
  <vmap:AdBreak timeOffset="50%" breakType="linear"><vmap:AdSource><vmap:AdTagURI>https://ads.example/half</vmap:AdTagURI></vmap:AdSource></vmap:AdBreak>
  <vmap:AdBreak timeOffset="end" breakType="linear" breakId="post">
    <vmap:AdSource><vmap:AdTagURI>https://ads.example/post</vmap:AdTagURI></vmap:AdSource>
  </vmap:AdBreak>
  <vmap:AdBreak timeOffset="#2" breakType="linear"><vmap:AdSource><vmap:AdTagURI>https://ads.example/x</vmap:AdTagURI></vmap:AdSource></vmap:AdBreak>
  <vmap:AdBreak timeOffset="start" breakType="nonlinear"><vmap:AdSource><vmap:AdTagURI>https://ads.example/y</vmap:AdTagURI></vmap:AdSource></vmap:AdBreak>
</vmap:VMAP>'''
            .replaceFirst('<?xml version="1.0" encoding="UTF-8"?>', ''),
      );
      final List<VmapBreak> breaks = (response as VmapTagResponse).breaks;
      expect(breaks, hasLength(4));
      expect(breaks[0].offset, isA<VmapStart>());
      expect(breaks[0].adTagUri, Uri.parse('https://ads.example/pre'));
      expect((breaks[1].offset as VmapTime).time, const Duration(seconds: 15));
      expect(breaks[1].inlineVast!.ads.single.id, 'a1');
      expect((breaks[2].offset as VmapPercent).percent, 50);
      expect(breaks[3].offset, isA<VmapEnd>());
    });

    test('rejects what is not VAST or VMAP', () {
      expect(() => parseAdTag('<html/>'), throwsA(isA<AdTagFormatException>()));
      expect(() => parseAdTag('not xml'), throwsA(isA<AdTagFormatException>()));
      expect(() => parseAdTag(''), throwsA(isA<AdTagFormatException>()));
    });

    test('an empty VAST has no ads', () {
      expect(parseVast('<VAST version="3.0"/>').ads, isEmpty);
    });
  });

  group('offsets', () {
    test('times and percentages', () {
      expect(
        parseVastTime('01:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(
        parseVastTime('00:00:05.25'),
        const Duration(seconds: 5, milliseconds: 250),
      );
      expect(parseVastTime('5'), isNull);
      expect(
        VastOffset.tryParse('25%')!.resolve(const Duration(seconds: 20)),
        const Duration(seconds: 5),
      );
      expect(VastOffset.tryParse('25%')!.resolve(null), isNull);
      expect(VastOffset.tryParse('120%'), isNull);
      expect(VmapOffset.tryParse('00:00:00'), isA<VmapStart>());
      expect(VmapOffset.tryParse('100%'), isA<VmapEnd>());
    });
  });

  group('pickMediaFile', () {
    VastMediaFile mp4(int h, {int? bitrate, String? delivery}) => VastMediaFile(
      url: Uri.parse('https://cdn.example/$h-$bitrate.mp4'),
      type: 'video/mp4',
      height: h,
      bitrate: bitrate,
      delivery: delivery ?? 'progressive',
    );

    test('the tallest MP4 up to 1080p, then the highest bitrate', () {
      expect(
        pickMediaFile(<VastMediaFile>[
          mp4(720),
          mp4(1080, bitrate: 3000),
          mp4(1080, bitrate: 6000),
          mp4(2160),
        ])!.url.path,
        '/1080-6000.mp4',
      );
    });

    test('the smallest MP4 when all are taller', () {
      expect(
        pickMediaFile(<VastMediaFile>[mp4(2160), mp4(1440)])!.height,
        1440,
      );
    });

    test('HLS when there is no MP4; never VPAID', () {
      final VastMediaFile hls = VastMediaFile(
        url: Uri.parse('https://cdn.example/ad.m3u8'),
        type: 'application/x-mpegURL',
        delivery: 'streaming',
      );
      final VastMediaFile vpaid = VastMediaFile(
        url: Uri.parse('https://cdn.example/ad.mp4'),
        type: 'video/mp4',
        apiFramework: 'VPAID',
      );
      expect(pickMediaFile(<VastMediaFile>[vpaid, hls]), same(hls));
      expect(pickMediaFile(<VastMediaFile>[vpaid]), isNull);
      expect(
        pickMediaFile(<VastMediaFile>[
          VastMediaFile(url: Uri.parse('https://x/a.webm'), type: 'video/webm'),
        ]),
        isNull,
      );
    });
  });

  group('expandVastMacros', () {
    test('fills the known macros, keeps the others', () {
      final Uri url = expandVastMacros(
        Uri.parse(
          'https://ads.example/e?c=[ERRORCODE]&cb=[CACHEBUSTING]&ph=[ADPLAYHEAD]&x=[UNKNOWN]',
        ),
        errorCode: 405,
        adPlayhead: const Duration(seconds: 3, milliseconds: 5),
        cacheBuster: 42,
      );
      expect(url.queryParameters['c'], '405');
      expect(url.queryParameters['cb'], '00000042');
      expect(url.queryParameters['ph'], '00:00:03.005');
      expect(url.queryParameters['x'], '[UNKNOWN]');
    });

    test('also when the brackets are percent-encoded', () {
      expect(
        expandVastMacros(
          Uri.parse('https://ads.example/e?c=%5BERRORCODE%5D'),
          errorCode: 303,
        ).queryParameters['c'],
        '303',
      );
    });
  });
}
