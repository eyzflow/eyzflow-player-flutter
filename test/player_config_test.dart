import 'dart:async';
import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The backend's answer (`toPublic`), as `sample-config.json` has it.
const Map<String, Object?> _remote = {
  'id': 'cfg_main01',
  'name': 'Main player',
  'isProtected': true,
  'theme': {
    'accentColor': '#ff0000',
    'backgroundColor': '#101010',
    'controlsBarColor': 'rgba(0,0,0,0.5)',
    'textColor': '#eeeeee',
    'borderRadius': '4px',
  },
  'features': {
    'controls': true,
    'autoPlay': false,
    'muted': false,
    'loop': true,
    'chromecast': false,
    'airplay': false,
    'qualitySelector': true,
    'captions': false,
    'pip': false,
    'ads': false,
    'autoHideControls': false,
    'adCountdown': false,
    'skipButtons': false,
    'endScreen': false,
  },
  'cast': {
    'receiverAppId': 'ABCD1234',
    'androidReceiverCompatible': false,
    'autoJoinPolicy': 'origin_scoped',
  },
  'ads': {'adTagUrl': '', 'countdownSeconds': 5},
  'endScreen': {'autoplaySeconds': 5, 'showAt': 'end', 'shrinkVideo': false},
};

void main() {
  setUp(PlayerConfigClient.clearCache);

  group('PlayerConfig.fromJson', () {
    test('reads the backend shape', () {
      final config = PlayerConfig.fromJson(_remote);
      expect(config.id, 'cfg_main01');
      expect(config.theme.accentColor, '#ff0000');
      expect(config.theme.borderRadius, '4px');
      expect(config.features.loop, isTrue);
      expect(config.features.chromecast, isFalse);
      expect(config.features.skipButtons, isFalse);
      expect(config.features.endScreen, isFalse);
      expect(config.endScreen?.autoplaySeconds, 5);
      expect(config.endScreen?.showAt, EndScreenShowAt.end);
      expect(config.endScreen?.shrinkVideo, isFalse);
      expect(config.castReceiverAppId, 'ABCD1234');
      expect(config.cast!.autoJoinPolicy, 'origin_scoped');
      expect(config.ads!.adTagUrl, '');
      // The backend sends no drm section.
      expect(config.drm, isNull);
      expect(config.toJson(), _remote);
    });

    test('missing or mistyped fields keep the defaults', () {
      final config = PlayerConfig.fromJson({
        'id': 'cfg_x',
        'theme': {'accentColor': 42},
        'features': {'loop': 'yes', 'captions': false},
        'cast': 'nope',
      });
      expect(config.name, 'Default');
      expect(config.theme, const PlayerTheme());
      expect(config.features, const PlayerFeatures(captions: false));
      expect(config.cast, isNull);
      expect(config.castReceiverAppId, isNull);
    });

    test('an empty receiver id is no receiver', () {
      final config = PlayerConfig.fromJson({
        'cast': {'receiverAppId': ''},
      });
      expect(config.castReceiverAppId, isNull);
    });

    test('drm parameters carry the storefront', () {
      final config = PlayerConfig.fromJson({
        'drm': {
          'parameters': {'storefront_id': 'sf-9', 'source': 'internal'},
        },
      });
      expect(config.drm!.storefrontId, 'sf-9');
      expect(config.drm!.parameters['source'], 'internal');
    });
  });

  group('mergePlayerConfig (the web player mergeConfig)', () {
    final remote = PlayerConfig.fromJson({
      ..._remote,
      'drm': {
        'parameters': {'storefront_id': 'sf-remote', 'source': 'web'},
      },
    });

    test('no inline config is the remote config', () {
      expect(mergePlayerConfig(remote, null), same(remote));
    });

    test('theme and features merge field by field', () {
      final merged = mergePlayerConfig(
        remote,
        const PlayerConfigOverride(
          theme: PlayerThemeOverride(textColor: '#000000'),
          features: PlayerFeaturesOverride(chromecast: true),
        ),
      );
      expect(merged.theme.textColor, '#000000');
      expect(merged.theme.accentColor, '#ff0000');
      expect(merged.features.chromecast, isTrue);
      expect(merged.features.loop, isTrue);
    });

    test('cast and ads are replaced as a whole', () {
      final merged = mergePlayerConfig(
        remote,
        const PlayerConfigOverride(cast: PlayerCastConfig(receiverAppId: 'X')),
      );
      expect(merged.castReceiverAppId, 'X');
      expect(merged.cast!.autoJoinPolicy, isNull);
      expect(merged.ads, same(remote.ads));
    });

    test('drm parameters merge, inline winning', () {
      final merged = mergePlayerConfig(
        remote,
        const PlayerConfigOverride(
          drm: PlayerDrmConfig(parameters: {'storefront_id': 'sf-inline'}),
        ),
      );
      expect(merged.drm!.parameters, {
        'storefront_id': 'sf-inline',
        'source': 'web',
      });
    });

    test('id, name and isProtected are overridable', () {
      final merged = mergePlayerConfig(
        remote,
        const PlayerConfigOverride(name: 'Inline', isProtected: false),
      );
      expect(merged.id, 'cfg_main01');
      expect(merged.name, 'Inline');
      expect(merged.isProtected, isFalse);
    });
  });

  group('PlayerConfigClient', () {
    test('loads the public config once and keeps it', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(_remote), 200);
      });
      final configs = PlayerConfigClient(
        client: client,
        endpoints: const EYZFlowEndpoints(api: 'https://api.dev.test/'),
      );

      final first = await configs.load('cfg_main01');
      final second = await configs.load('cfg_main01');

      expect(first!.id, 'cfg_main01');
      expect(second, same(first));
      expect(requests, hasLength(1));
      expect(
        requests.single.url.toString(),
        'https://api.dev.test/v1/player-configs/cfg_main01',
      );
      expect(requests.single.method, 'GET');
      // Public: no Authorization.
      expect(requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('caches per config id, shared across clients', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls += 1;
        return http.Response(
          jsonEncode({'id': request.url.pathSegments.last}),
          200,
        );
      });
      expect(
        (await PlayerConfigClient(client: client).load('cfg_a'))!.id,
        'cfg_a',
      );
      expect(
        (await PlayerConfigClient(client: client).load('cfg_b'))!.id,
        'cfg_b',
      );
      await PlayerConfigClient(client: client).load('cfg_a');
      expect(calls, 2);
    });

    test('encodes the config id into the path', () async {
      Uri? url;
      final client = MockClient((request) async {
        url = request.url;
        return http.Response('{}', 200);
      });
      await PlayerConfigClient(client: client).load('a/b c');
      expect(url!.path, '/v1/player-configs/a%2Fb%20c');
    });

    test('a 404 falls back to the defaults and is not kept', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls += 1;
        return http.Response(
          jsonEncode({'statusCode': 404, 'message': 'not found'}),
          404,
        );
      });
      final configs = PlayerConfigClient(client: client);
      expect(await configs.load('cfg_gone'), isNull);
      await expectLater(
        configs.fetch('cfg_gone'),
        throwsA(
          isA<PlayerConfigException>().having(
            (e) => e.reason,
            'reason',
            'HTTP 404',
          ),
        ),
      );
      expect(calls, 2);
    });

    test('a body that is not a JSON object falls back', () async {
      final configs = PlayerConfigClient(
        client: MockClient((_) async => http.Response('<html>', 200)),
      );
      expect(await configs.load('cfg_html'), isNull);
      final list = PlayerConfigClient(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(await list.load('cfg_list'), isNull);
    });

    test('no network falls back', () async {
      final configs = PlayerConfigClient(
        client: MockClient((_) => throw http.ClientException('offline')),
      );
      expect(await configs.load('cfg_offline'), isNull);
    });

    test('a slow API falls back after the timeout', () async {
      final never = Completer<http.Response>();
      final configs = PlayerConfigClient(
        client: MockClient((_) => never.future),
        timeout: const Duration(milliseconds: 10),
      );
      expect(await configs.load('cfg_slow'), isNull);
    });
  });

  group('PlayerOptions.fromConfig', () {
    test('maps features and theme', () {
      final options = PlayerOptions.fromConfig(PlayerConfig.fromJson(_remote));
      expect(options.loop, isTrue);
      expect(options.captions, isFalse);
      expect(options.autoHideControls, isFalse);
      expect(options.pictureInPicture, isFalse);
      expect(options.airPlay, isFalse);
      expect(options.controls, isTrue);
      final theme = options.controlsTheme;
      expect(theme.accentColor, const Color(0xFFFF0000));
      expect(theme.textColor, const Color(0xFFEEEEEE));
      expect(theme.panelColor, const Color(0xFF101010));
      expect(theme.barColor, const Color.fromARGB(128, 0, 0, 0));
      expect(theme.radius, 4);
      expect(theme.onFocusColor, const Color(0xFFFFFFFF));
    });

    test('the defaults change nothing', () {
      expect(
        PlayerOptions.fromConfig(PlayerConfig.defaults, applyTheme: false),
        const PlayerOptions(),
      );
    });

    test('an unreadable colour keeps the overlay colour', () {
      final theme = PlayerControlsTheme.fromPlayerTheme(
        const PlayerTheme(
          accentColor: 'tomato',
          textColor: 'var(--x)',
          borderRadius: '1rem',
        ),
      );
      expect(theme.accentColor, isNull);
      expect(theme.focusColor, const Color(0xFFFFFFFF));
      expect(theme.textColor, const PlayerControlsTheme().textColor);
      expect(theme.radius, const PlayerControlsTheme().radius);
    });
  });

  group('parseCssColor', () {
    test('reads the dashboard formats', () {
      expect(parseCssColor('#615fff'), const Color(0xFF615FFF));
      expect(parseCssColor(' #FFF '), const Color(0xFFFFFFFF));
      expect(parseCssColor('#f008'), const Color(0x88FF0000));
      expect(parseCssColor('#11223344'), const Color(0x44112233));
      expect(
        parseCssColor('rgba(10,10,10,0.88)'),
        const Color.fromARGB(224, 10, 10, 10),
      );
      expect(parseCssColor('rgb(1, 2, 3)'), const Color(0xFF010203));
      expect(
        parseCssColor('rgba(0,0,0,50%)'),
        const Color.fromARGB(128, 0, 0, 0),
      );
    });

    test('anything else is null', () {
      for (final value in [
        '',
        'red',
        '#12',
        '#ggg',
        'rgb(1,2)',
        'rgb(1.2.3,0,0)',
        'hsl(0,0%,0%)',
      ]) {
        expect(parseCssColor(value), isNull, reason: value);
      }
    });

    test('parseCssLength reads px', () {
      expect(parseCssLength('10px'), 10);
      expect(parseCssLength('0'), 0);
      expect(parseCssLength('2.5 px'), 2.5);
      expect(parseCssLength('1rem'), isNull);
      expect(parseCssLength('-4px'), isNull);
    });
  });

  group('watchProgress.completedPercent', () {
    double percent(Object? json) => PlayerConfig.fromJson({
      'watchProgress': ?json,
    }).watchProgressCompletedPercent;

    test('defaults to 95', () {
      expect(PlayerConfig.defaults.watchProgressCompletedPercent, 95);
      expect(percent(null), 95);
      expect(percent(<String, Object?>{}), 95);
      expect(percent({'completedPercent': '90'}), 95);
      expect(percent('90'), 95);
    });

    test('reads the config and clamps it to 50–100', () {
      expect(percent({'completedPercent': 90}), 90);
      expect(percent({'completedPercent': 92.5}), 92.5);
      expect(percent({'completedPercent': 100}), 100);
      expect(percent({'completedPercent': 20}), 50);
      expect(percent({'completedPercent': 400}), 100);
    });

    test('round-trips through toJson', () {
      final config = PlayerConfig.fromJson({
        'watchProgress': {'completedPercent': 90},
      });
      expect(config.toJson()['watchProgress'], {'completedPercent': 90.0});
      expect(PlayerConfig.defaults.toJson(), isNot(contains('watchProgress')));
    });

    test('an inline config wins; leaving it out keeps the remote one', () {
      final remote = PlayerConfig.fromJson({
        'watchProgress': {'completedPercent': 90},
      });
      expect(
        mergePlayerConfig(
          remote,
          const PlayerConfigOverride(isProtected: false),
        ).watchProgressCompletedPercent,
        90,
      );
      expect(
        mergePlayerConfig(
          remote,
          const PlayerConfigOverride(
            watchProgress: PlayerWatchProgressConfig(completedPercent: 80),
          ),
        ).watchProgressCompletedPercent,
        80,
      );
      expect(
        mergePlayerConfig(
          remote,
          const PlayerConfigOverride(
            watchProgress: PlayerWatchProgressConfig(),
          ),
        ).watchProgressCompletedPercent,
        90,
      );
    });
  });
}
