import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/ad_scheduler.dart';
import 'package:eyzflow_player/src/ads/vast.dart';
import 'package:eyzflow_player/src/ads/vast_ad_driver.dart';
import 'package:eyzflow_player/src/ads/vast_loader.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_ad_player.dart';

const String _tag = 'https://ads.example/tag';

/// The real scheduler and driver, with ad tags served from [pages], ad
/// players faked, and the content player reduced to counters.
final class _Harness {
  _Harness(
    this.pages, {
    List<AdBreak> markers = const <AdBreak>[],
    this.failing = const <String>{},
    this.hanging = const <String>{},
    this.contentLength,
  }) {
    final client = MockClient((http.Request request) async {
      final String? body = pages[request.url.toString()];
      return body == null ? http.Response('', 404) : http.Response(body, 200);
    });
    driver = VastAdDriver(
      adTagUrl: _tag,
      loader: VastLoader(client: client, ping: pings.add),
      createPlayer: (VastMediaFile media) {
        final String id = media.url.pathSegments.last.split('.').first;
        if (pauses == resumes && !inPostroll) {
          // Mid-roll only: the content must already be paused.
          playersCreatedWhilePlaying += afterContentStarted ? 1 : 0;
        }
        final FakeAdPlayer player = FakeAdPlayer(
          media,
          failInitialize: failing.contains(id),
          hangInitialize: hanging.contains(id),
        );
        players.add(player);
        return player;
      },
      ping: pings.add,
      onPauseContent: () => pauses++,
      onResumeContent: () => resumes++,
      onReleaseContent: () {
        releases++;
        inPostroll = true;
      },
      contentDuration: () => contentLength,
    );
    scheduler = AdBreakScheduler(ads: ads, driver: driver);
    driver.scheduler = scheduler;
    ads.loadMarkers(() async => markers);
  }

  final Map<String, String> pages;
  final Set<String> failing;
  final Set<String> hanging;
  final Duration? contentLength;
  final PlayerAds ads = PlayerAds(adTagUrl: _tag);
  late final VastAdDriver driver;
  late final AdBreakScheduler scheduler;
  final List<Uri> pings = <Uri>[];
  final List<FakeAdPlayer> players = <FakeAdPlayer>[];
  var pauses = 0;
  var resumes = 0;
  var releases = 0;
  var inPostroll = false;
  var afterContentStarted = false;
  var playersCreatedWhilePlaying = 0;

  FakeAdPlayer get current => players.last;

  List<String> get pinged => <String>[
    for (final Uri u in pings) u.host == 'track.example' ? u.path : '$u',
  ];

  /// Content plays from [from] to [to] in small steps.
  void play(FakeAsync async, int from, int to) {
    afterContentStarted = true;
    for (var s = from * 2; s <= to * 2; s++) {
      scheduler.contentPosition(Duration(milliseconds: s * 500));
      async.flushMicrotasks();
    }
  }

  void dispose() {
    scheduler.dispose();
    driver.dispose();
  }
}

void main() {
  test('a VAST pre-roll plays before the content, with its tracking', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(<String, String>{_tag: vastOf(vastAd())});
      var contentMayStart = false;
      h.scheduler.beforeContent().then((_) => contentMayStart = true);
      async.flushMicrotasks();

      expect(h.players, hasLength(1));
      expect(h.current.played, isTrue);
      expect(h.scheduler.inBreak, isTrue);
      expect(h.driver.playback.value!.index, 1);
      expect(h.pinged, isEmpty, reason: 'no impression before a frame');

      h.current.advance(const Duration(seconds: 1));
      expect(h.pinged, <String>['/imp/a', '/start/a']);
      h.current.complete();
      async.flushMicrotasks();

      expect(h.pinged.last, '/complete/a');
      expect(contentMayStart, isTrue);
      expect(h.scheduler.inBreak, isFalse);
      expect(h.current.disposed, isTrue);
      expect(h.driver.playback.value, isNull);
      expect(h.pauses, 0, reason: 'nothing to pause before the content');
      h.dispose();
    });
  });

  test('an ad pod plays in order; Skip only after the offset', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(<String, String>{
        _tag: vastOf(
          vastAd(id: 'b', sequence: 2, skip: ' skipoffset="00:00:05"') +
              vastAd(id: 'a', sequence: 1),
        ),
      });
      var done = false;
      h.scheduler.beforeContent().then((_) => done = true);
      async.flushMicrotasks();
      expect(h.current.media.url.path, '/a.mp4');
      expect(h.driver.playback.value!.skipAt, isNull);
      h.current.complete();
      async.flushMicrotasks();

      expect(h.players, hasLength(2));
      expect(h.driver.playback.value!.index, 2);
      expect(h.driver.playback.value!.count, 2);
      h.current.advance(const Duration(seconds: 2));
      expect(h.driver.playback.value!.canSkip, isFalse);
      expect(h.driver.playback.value!.skipIn, 3);
      h.driver.skip();
      async.flushMicrotasks();
      expect(done, isFalse, reason: 'too early to skip');

      h.current.advance(const Duration(seconds: 5));
      expect(h.driver.playback.value!.canSkip, isTrue);
      h.driver.skip();
      async.flushMicrotasks();
      expect(h.pinged, contains('/skip/b'));
      expect(h.pinged, isNot(contains('/complete/b')));
      expect(done, isTrue);
      h.dispose();
    });
  });

  test('an ad that fails is reported and the next one plays', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(
        <String, String>{
          _tag: vastOf(
            vastAd(id: 'a', sequence: 1) + vastAd(id: 'b', sequence: 2),
          ),
        },
        failing: <String>{'a'},
      );
      var done = false;
      h.scheduler.beforeContent().then((_) => done = true);
      async.flushMicrotasks();
      expect(h.pings, contains(Uri.parse('https://track.example/err/a?c=405')));
      expect(h.current.media.url.path, '/b.mp4');
      h.current.fail('decoder gone');
      async.flushMicrotasks();
      expect(h.pings, contains(Uri.parse('https://track.example/err/b?c=405')));
      expect(done, isTrue);
      h.dispose();
    });
  });

  test('an ad that never starts gives up after 10 s with 402', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(
        <String, String>{_tag: vastOf(vastAd())},
        hanging: <String>{'a'},
      );
      var done = false;
      h.scheduler.beforeContent().then((_) => done = true);
      async.elapse(const Duration(seconds: 9));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(h.pings, contains(Uri.parse('https://track.example/err/a?c=402')));
      expect(done, isTrue);
      h.dispose();
    });
  });

  test('an ad that stalls for 10 s ends', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(<String, String>{_tag: vastOf(vastAd())});
      var done = false;
      h.scheduler.beforeContent().then((_) => done = true);
      async.flushMicrotasks();
      h.current.advance(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 11));
      expect(done, isTrue);
      expect(h.current.disposed, isTrue);
      h.dispose();
    });
  });

  test('an empty or failing tag lets the content start, no player', () {
    fakeAsync((FakeAsync async) {
      for (final String? body in <String?>[vastOf(''), 'garbage', null]) {
        final h = _Harness(<String, String>{_tag: ?body});
        var done = false;
        h.scheduler.beforeContent().then((_) => done = true);
        async.flushMicrotasks();
        expect(done, isTrue, reason: '$body');
        expect(h.players, isEmpty);
        h.dispose();
      }
    });
  });

  group('VMAP without markers', () {
    Map<String, String> pages() => <String, String>{
      _tag: vmapOf(<String, String>{
        'start': 'https://ads.example/pre',
        '00:00:15.000': 'https://ads.example/mid',
        'end': 'https://ads.example/post',
      }),
      'https://ads.example/pre': vastOf(vastAd(id: 'pre')),
      'https://ads.example/mid': vastOf(vastAd(id: 'mid')),
      'https://ads.example/post': vastOf(vastAd(id: 'post')),
    };

    test('pre-roll, mid-roll at its cue point and post-roll', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(pages());
        var started = false;
        h.scheduler.beforeContent().then((_) => started = true);
        async.flushMicrotasks();
        expect(h.current.media.url.path, '/pre.mp4');
        h.current.complete();
        async.flushMicrotasks();
        expect(started, isTrue);
        expect(h.scheduler.upcomingMidrolls, <Duration>[
          const Duration(seconds: 15),
        ]);

        h.play(async, 0, 14);
        expect(h.players, hasLength(1));
        h.play(async, 14, 16);
        expect(h.players, hasLength(2));
        expect(h.current.media.url.path, '/mid.mp4');
        expect(h.pauses, 1);
        expect(h.playersCreatedWhilePlaying, 0);
        expect(h.scheduler.inBreak, isTrue);
        h.current.complete();
        async.flushMicrotasks();
        expect(h.resumes, 1);
        expect(h.scheduler.inBreak, isFalse);

        var closed = false;
        h.scheduler.contentCompleted().then((_) => closed = true);
        async.flushMicrotasks();
        expect(h.releases, 1);
        expect(h.current.media.url.path, '/post.mp4');
        expect(closed, isFalse);
        h.current.complete();
        async.flushMicrotasks();
        expect(closed, isTrue);
        expect(h.resumes, 1, reason: 'the content is not resumed after it');
        h.dispose();
      });
    });

    test('a mid-roll seeked past does not play', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(pages());
        h.scheduler.beforeContent();
        async.flushMicrotasks();
        h.current.complete();
        async.flushMicrotasks();
        h.play(async, 0, 10);
        h.scheduler.contentPosition(const Duration(seconds: 30));
        async.flushMicrotasks();
        h.play(async, 30, 40);
        expect(h.players, hasLength(1));
        h.dispose();
      });
    });

    test('a percentage break needs the content length', () {
      fakeAsync((FakeAsync async) {
        final h = _Harness(<String, String>{
          _tag: vmapOf(<String, String>{
            'start': 'https://ads.example/pre',
            '50%': 'https://ads.example/mid',
          }),
          'https://ads.example/pre': vastOf(vastAd(id: 'pre')),
          'https://ads.example/mid': vastOf(vastAd(id: 'mid')),
        }, contentLength: const Duration(seconds: 40));
        h.scheduler.beforeContent();
        async.flushMicrotasks();
        h.current.complete();
        async.flushMicrotasks();
        expect(h.scheduler.upcomingMidrolls, <Duration>[
          const Duration(seconds: 20),
        ]);
        h.dispose();
      });
    });
  });

  test('with markers, a VAST mid-roll plays at the marker with the '
      'content paused first', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(
        <String, String>{_tag: vastOf(vastAd(id: 'm'))},
        markers: const <AdBreak>[
          AdBreak(id: 'b8', start: Duration(seconds: 8)),
        ],
      );
      var started = false;
      h.scheduler.beforeContent().then((_) => started = true);
      async.flushMicrotasks();
      expect(started, isTrue, reason: 'no marker at 0: no pre-roll');
      expect(h.players, isEmpty);

      h.play(async, 0, 9);
      expect(h.pauses, 1);
      expect(h.players, hasLength(1));
      expect(h.playersCreatedWhilePlaying, 0);
      h.current.complete();
      async.flushMicrotasks();
      expect(h.resumes, 1);

      h.scheduler.contentPosition(const Duration(seconds: 2));
      h.play(async, 2, 10);
      expect(h.players, hasLength(1), reason: 'each break plays once');
      h.dispose();
    });
  });

  test('disposing during an ad disposes its player', () {
    fakeAsync((FakeAsync async) {
      final h = _Harness(<String, String>{_tag: vastOf(vastAd())});
      h.scheduler.beforeContent();
      async.flushMicrotasks();
      final FakeAdPlayer player = h.current;
      h.dispose();
      async.flushMicrotasks();
      expect(player.disposed, isTrue);
      expect(h.pinged, isNot(contains('/complete/a')));
    });
  });
}
