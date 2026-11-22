import 'package:eyzflow_player/src/ads/ad_tag.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _custParams(String url) =>
    Uri.splitQueryString(Uri.parse(url).queryParameters['cust_params']!);

void main() {
  group('withTargeting', () {
    test('adds cust_params to a tag without any', () {
      final out = withTargeting(
        'https://ads.example.com/gampad/ads?iu=/1/x&sz=640x480',
        {'plan': 'basic-ads', 'access': 'svod'},
      );

      expect(Uri.parse(out).queryParameters['iu'], '/1/x');
      expect(Uri.parse(out).queryParameters['sz'], '640x480');
      expect(_custParams(out), {'plan': 'basic-ads', 'access': 'svod'});
      expect(
        out,
        'https://ads.example.com/gampad/ads?iu=/1/x&sz=640x480'
        '&cust_params=plan%3Dbasic-ads%26access%3Dsvod',
      );
    });

    test("keeps the tag's own cust_params and lets them win", () {
      final tag =
          'https://ads.example.com/ads?a=1&cust_params='
          '${Uri.encodeQueryComponent('genre=drama&plan=fixed')}&b=2';

      final out = withTargeting(tag, {'plan': 'basic-ads', 'access': 'svod'});

      expect(_custParams(out), {
        'genre': 'drama',
        'plan': 'fixed',
        'access': 'svod',
      });
      expect(Uri.parse(out).queryParameters['a'], '1');
      expect(Uri.parse(out).queryParameters['b'], '2');
    });

    test(
      'encodes values and keeps a tag without a query or with a fragment',
      () {
        expect(
          _custParams(
            withTargeting('https://ads.example.com/vast', {'k': 'a b&c=d'}),
          ),
          {'k': 'a b&c=d'},
        );
        final out = withTargeting('https://ads.example.com/v?x=1#frag', {
          'plan': 'p',
        });
        expect(out, 'https://ads.example.com/v?x=1&cust_params=plan%3Dp#frag');
      },
    );

    test('leaves the tag alone with nothing to add or when not a URL', () {
      expect(
        withTargeting('https://ads.example.com/ads?a=1', {}),
        'https://ads.example.com/ads?a=1',
      );
      expect(withTargeting('not a url', {'plan': 'x'}), 'not a url');
      expect(withTargeting('/relative?a=1', {'plan': 'x'}), '/relative?a=1');
    });
  });

  group('planAdTag', () {
    const tag = 'https://ads.example.com/ads?a=1';

    test('a plan without ads requests none', () {
      expect(planAdTag(tag, planAds: false), isNull);
      expect(
        planAdTag(tag, planAds: false, targeting: {'plan': 'free'}),
        isNull,
      );
    });

    test('a plan with ads, or no answer, leaves it to the config', () {
      expect(planAdTag(tag, planAds: true), tag);
      expect(planAdTag(tag), tag);
      expect(planAdTag(null, planAds: true), isNull);
      expect(planAdTag(null), isNull);
    });

    test('adds the targeting to the tag', () {
      expect(
        planAdTag(tag, planAds: true, targeting: {'plan': 'basic-ads'}),
        '$tag&cust_params=plan%3Dbasic-ads',
      );
    });
  });
}
