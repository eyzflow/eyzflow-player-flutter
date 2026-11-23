import 'package:eyzflow_player/src/ads/vast.dart';
import 'package:eyzflow_player/src/ads/vast_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String inlineAd({
  String id = 'a',
  int? sequence,
  String media = 'https://cdn.example/a.mp4',
  String type = 'video/mp4',
  String skip = '',
  String tracking = '',
}) =>
    '''
<Ad id="$id"${sequence == null ? '' : ' sequence="$sequence"'}><InLine>
  <Impression>https://ads.example/imp/$id</Impression>
  <Error>https://ads.example/err/$id?c=[ERRORCODE]</Error>
  <Creatives><Creative><Linear$skip>
    <Duration>00:00:10</Duration>
    <TrackingEvents>$tracking</TrackingEvents>
    <MediaFiles><MediaFile delivery="progressive" type="$type" height="720">$media</MediaFile></MediaFiles>
  </Linear></Creative></Creatives>
</InLine></Ad>''';

String vast(String ads, {String errors = ''}) =>
    '<VAST version="3.0">$errors$ads</VAST>';

String wrapperAd(String next, {String id = 'w', int? sequence}) =>
    '''
<Ad id="$id"${sequence == null ? '' : ' sequence="$sequence"'}><Wrapper>
  <VASTAdTagURI>$next</VASTAdTagURI>
  <Impression>https://ads.example/imp/$id</Impression>
  <Error>https://ads.example/err/$id?c=[ERRORCODE]</Error>
  <Creatives><Creative><Linear><TrackingEvents>
    <Tracking event="start">https://ads.example/start/$id</Tracking>
  </TrackingEvents></Linear></Creative></Creatives>
</Wrapper></Ad>''';

void main() {
  late Map<String, String> pages;
  late List<Uri> pings;
  late VastLoader loader;

  setUp(() {
    pages = <String, String>{};
    pings = <Uri>[];
    loader = VastLoader(
      client: MockClient((http.Request request) async {
        final String? body = pages[request.url.toString()];
        return body == null
            ? http.Response('nope', 404)
            : http.Response(body, 200);
      }),
      ping: pings.add,
    );
  });

  Future<List<PlayableAd>> resolve(String body) =>
      loader.resolve(parseVast(body));

  test('a standalone ad resolves to its creative', () async {
    final List<PlayableAd> ads = await resolve(vast(inlineAd()));
    expect(ads.single.media.url, Uri.parse('https://cdn.example/a.mp4'));
    expect(ads.single.duration, const Duration(seconds: 10));
    expect(pings, isEmpty);
  });

  test('a pod plays in sequence order; standalone ads beside it are '
      'not played', () async {
    final List<PlayableAd> ads = await resolve(
      vast(
        inlineAd(id: 'b', sequence: 2) +
            inlineAd(id: 'x') +
            inlineAd(id: 'a', sequence: 1),
      ),
    );
    expect(ads.map((PlayableAd a) => a.id), <String>['a', 'b']);
  });

  test('without a pod, the first standalone ad that plays', () async {
    final List<PlayableAd> ads = await resolve(
      vast(inlineAd(id: 'flash', type: 'video/x-flv') + inlineAd(id: 'ok')),
    );
    expect(ads.single.id, 'ok');
    // The one with no TV media reported 403.
    expect(pings.single.toString(), 'https://ads.example/err/flash?c=403');
  });

  test('wrappers are followed, and their tracking merged in', () async {
    pages['https://ads.example/w1'] = vast(
      wrapperAd('https://ads.example/w2', id: 'w2'),
    );
    pages['https://ads.example/w2'] = vast(inlineAd(id: 'in'));
    final List<PlayableAd> ads = await resolve(
      vast(wrapperAd('https://ads.example/w1', id: 'w1')),
    );
    final PlayableAd ad = ads.single;
    expect(ad.id, 'in');
    expect(ad.impressions.map((Uri u) => u.path), <String>[
      '/imp/w1',
      '/imp/w2',
      '/imp/in',
    ]);
    expect(
      ad.tracking.where((t) => t.event == 'start').map((t) => t.url.path),
      <String>['/start/w1', '/start/w2'],
    );
  });

  test('a wrapper leading nowhere reports 301 or 303', () async {
    pages['https://ads.example/empty'] = vast('');
    expect(await resolve(vast(wrapperAd('https://ads.example/gone'))), isEmpty);
    expect(pings, contains(Uri.parse('https://ads.example/err/w?c=301')));
    pings.clear();
    expect(
      await resolve(vast(wrapperAd('https://ads.example/empty'))),
      isEmpty,
    );
    expect(pings, contains(Uri.parse('https://ads.example/err/w?c=303')));
  });

  test('a sixth wrapper in a row is not followed: 302', () async {
    for (var i = 0; i < 10; i++) {
      pages['https://ads.example/w$i'] = vast(
        wrapperAd('https://ads.example/w${i + 1}', id: 'w$i'),
      );
    }
    expect(await resolve(vast(wrapperAd('https://ads.example/w0'))), isEmpty);
    expect(pings, contains(Uri.parse('https://ads.example/err/w4?c=302')));
  });

  test('a response with no ad pings its root error URL with 303', () async {
    expect(
      await resolve(
        vast(
          '',
          errors: '<Error>https://ads.example/none?c=[ERRORCODE]</Error>',
        ),
      ),
      isEmpty,
    );
    expect(pings.single, Uri.parse('https://ads.example/none?c=303'));
  });

  group('VastAdTracker', () {
    test('fires each event once, quartiles as they are passed', () async {
      final PlayableAd ad = (await resolve(
        vast(
          inlineAd(
            tracking: '''
<Tracking event="start">https://t/start</Tracking>
<Tracking event="firstQuartile">https://t/q1</Tracking>
<Tracking event="midpoint">https://t/mid</Tracking>
<Tracking event="thirdQuartile">https://t/q3</Tracking>
<Tracking event="complete">https://t/done</Tracking>
<Tracking event="progress" offset="00:00:04">https://t/p4</Tracking>
<Tracking event="skip">https://t/skip</Tracking>''',
          ),
        ),
      )).single;
      final List<String> fired = <String>[];
      final VastAdTracker tracker = VastAdTracker(
        ad: ad,
        ping: (Uri u) => fired.add(u.host == 't' ? u.path : 'imp'),
      );
      tracker.progress(const Duration(seconds: 3), null);
      expect(fired, isEmpty, reason: 'nothing before the first frame');
      tracker.started();
      tracker.started();
      expect(fired, <String>['imp', '/start']);
      tracker.progress(const Duration(seconds: 3), null);
      expect(fired.last, '/q1');
      tracker.progress(const Duration(seconds: 5), null);
      expect(fired.sublist(3), <String>['/mid', '/p4']);
      tracker.completed();
      tracker.completed();
      expect(fired.sublist(5), <String>['/q3', '/done']);
      tracker.skipped();
      expect(fired.last, '/skip');
    });

    test('an error pings the error URLs once, with its code', () async {
      final PlayableAd ad = (await resolve(vast(inlineAd()))).single;
      final List<Uri> fired = <Uri>[];
      final VastAdTracker tracker = VastAdTracker(ad: ad, ping: fired.add);
      tracker.failed(405);
      tracker.failed(402);
      expect(fired.single.toString(), 'https://ads.example/err/a?c=405');
    });
  });
}
