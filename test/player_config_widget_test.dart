import 'dart:async';
import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/player_controls_bloc.dart';
import 'package:eyzflow_player/src/player/default_player_builder.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _red = Color(0xFFFF0000);

/// A dashboard config, plus a `drm` section as an inline config would carry
/// one (the backend stores none today).
Map<String, Object?> _config({
  bool chromecast = true,
  String receiver = '',
  Map<String, Object?>? drmParameters,
}) => {
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
  'features': {'chromecast': chromecast, 'loop': true, 'captions': false},
  'cast': {'receiverAppId': receiver},
  'drm': ?switch (drmParameters) {
    final Map<String, Object?> p => {'parameters': p},
    null => null,
  },
};

const _tv = CastTarget(id: 'tv-1', name: 'Living Room TV', model: 'Chromecast');

final class _Backend implements CastBackend {
  var scans = 0;
  String? appId;

  @override
  Future<List<CastTarget>> discover({Duration? timeout}) async {
    scans += 1;
    return const [_tv];
  }

  @override
  Future<CastConnection> connect(
    CastTarget target, {
    required String appId,
  }) async {
    this.appId = appId;
    return _Tv();
  }
}

final class _Tv implements CastConnection {
  final _playback = StreamController<CastPlayback>.broadcast();

  @override
  Stream<CastPlayback> get playback => _playback.stream;
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  CastPlayback get current => const CastPlayback();
  @override
  Future<void> load(CastMedia media) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async {}
}

/// The API: the player config, playback sessions.
MockClient _api({
  Map<String, Object?>? config,
  int configStatus = 200,
  List<http.Request>? requests,
  Map<String, Object?> session = const {'id': 'ps_1'},
}) => MockClient((request) async {
  requests?.add(request);
  if (request.url.path.startsWith('/v1/player-configs/')) {
    return http.Response(jsonEncode(config ?? {}), configStatus);
  }
  if (request.method == 'DELETE') return http.Response('', 204);
  if (request.url.path.endsWith('/heartbeat')) {
    return http.Response(jsonEncode({'status': 'active'}), 200);
  }
  return http.Response(jsonEncode(session), 201);
});

Future<_Backend> _pump(
  WidgetTester tester, {
  required MockClient client,
  String? configId = 'cfg_main01',
  PlayerConfigOverride? config,
  String? storefrontId,
  Map<String, Object?> drmParameters = const {},
  String? castReceiverAppId,
  List<EyzflowSource>? mounted,
}) async {
  final backend = _Backend();
  await tester.pumpWidget(
    MaterialApp(
      home: EyzflowPlayer(
        streamId: 'stream-1',
        title: 'Film',
        sourceType: const EyzflowFilm('cat-1'),
        drmAuthorization: 'Bearer viewer',
        storefrontId: storefrontId,
        drmParameters: drmParameters,
        configId: configId,
        config: config,
        httpClient: client,
        deviceIdStore: MemoryDeviceIdStore('device-1'),
        castReceiverAppId: castReceiverAppId,
        castBackend: backend,
        debugOperatingSystemOverride: 'android',
        playerBuilder: (context, target) {
          mounted?.add(switch (target) {
            VideoplayerSourceTarget(:final source) => source,
            VideoplayerTrailerTarget(:final source) => source,
          });
          return const SizedBox(key: Key('player'));
        },
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return backend;
}

VideoplayerFeatureView _view(WidgetTester tester) =>
    tester.widget<VideoplayerFeatureView>(find.byType(VideoplayerFeatureView));

Map<Object?, Object?> _tokenParameters(EyzflowSource source) =>
    (jsonDecode(utf8.decode(base64Decode(source.drmAccessHeader!)))
            as Map)['parameters']
        as Map;

void main() {
  setUpAll(() => setEyzflowPlayerLanguage('en'));
  setUp(PlayerConfigClient.clearCache);

  group("EyzflowPlayer ads and the viewer's plan", () {
    const tag = 'https://ads.example.com/ads?iu=/1/x';
    Map<String, Object?> adsConfig() => {
      ..._config(),
      'features': {'ads': true},
      'ads': {'adTagUrl': tag},
    };

    testWidgets('a plan without ads requests none', (tester) async {
      await _pump(
        tester,
        client: _api(
          config: adsConfig(),
          session: {'id': 'ps_1', 'ads': false},
        ),
        storefrontId: 'sf',
      );

      expect(_view(tester).options.ads, isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a plan with ads plays the config's tag, targeted", (
      tester,
    ) async {
      await _pump(
        tester,
        client: _api(
          config: adsConfig(),
          session: {
            'id': 'ps_1',
            'ads': true,
            'ad_targeting': {'plan': 'basic-ads', 'access': 'svod'},
          },
        ),
        storefrontId: 'sf',
      );

      expect(
        _view(tester).options.ads?.adTagUrl,
        '$tag&cust_params=plan%3Dbasic-ads%26access%3Dsvod',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older backend or no session: the config decides', (
      tester,
    ) async {
      await _pump(
        tester,
        client: _api(config: adsConfig()),
        storefrontId: 'sf',
      );
      expect(_view(tester).options.ads?.adTagUrl, tag);
      await tester.pumpWidget(const SizedBox());

      await _pump(tester, client: _api(config: adsConfig()));
      expect(_view(tester).options.ads?.adTagUrl, tag);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a plan with ads cannot turn on ads the config has off', (
      tester,
    ) async {
      await _pump(
        tester,
        client: _api(config: _config(), session: {'id': 'ps_1', 'ads': true}),
        storefrontId: 'sf',
      );

      expect(_view(tester).options.ads, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('EyzflowPlayer with a configId', () {
    testWidgets('hands the config theme and features to the player', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _pump(
        tester,
        client: _api(config: _config(), requests: requests),
        storefrontId: 'sf',
      );

      expect(requests.first.url.path, '/v1/player-configs/cfg_main01');
      final options = _view(tester).options;
      expect(options.controlsTheme.accentColor, _red);
      expect(options.controlsTheme.radius, 4);
      expect(options.loop, isTrue);
      expect(options.captions, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the config DRM parameters reach the access token, '
        'storefront included', (tester) async {
      final requests = <http.Request>[];
      final mounted = <EyzflowSource>[];
      await _pump(
        tester,
        client: _api(
          config: _config(
            drmParameters: {'storefront_id': 'sf-cfg', 'source': 'cfg'},
          ),
          requests: requests,
        ),
        mounted: mounted,
      );

      expect(_tokenParameters(mounted.last), {
        'storefront_id': 'sf-cfg',
        'source': 'cfg',
        'device_id': 'device-1',
        'playback_session_id': 'ps_1',
      });
      // The config's storefront opens the playback session too.
      expect(
        requests.where((r) => r.method == 'POST').single.url.path,
        contains('sf-cfg'),
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('inline DRM parameters and storefront win over the config', (
      tester,
    ) async {
      final mounted = <EyzflowSource>[];
      await _pump(
        tester,
        client: _api(
          config: _config(
            drmParameters: {'storefront_id': 'sf-cfg', 'source': 'cfg'},
          ),
        ),
        storefrontId: 'sf',
        drmParameters: const {'source': 'inline'},
        mounted: mounted,
      );

      expect(_tokenParameters(mounted.last), {
        'storefront_id': 'sf',
        'source': 'inline',
        'device_id': 'device-1',
        'playback_session_id': 'ps_1',
      });
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an inline config overrides the remote one', (tester) async {
      final mounted = <EyzflowSource>[];
      await _pump(
        tester,
        client: _api(config: _config()),
        storefrontId: 'sf',
        config: const PlayerConfigOverride(
          theme: PlayerThemeOverride(accentColor: '#00ff00'),
          features: PlayerFeaturesOverride(loop: false),
          drm: PlayerDrmConfig(parameters: {'source': 'inline-config'}),
        ),
        mounted: mounted,
      );

      final options = _view(tester).options;
      expect(options.controlsTheme.accentColor, const Color(0xFF00FF00));
      expect(options.controlsTheme.textColor, const Color(0xFFEEEEEE));
      expect(options.loop, isFalse);
      expect(_tokenParameters(mounted.last)['source'], 'inline-config');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an unknown config plays with the defaults', (tester) async {
      await _pump(tester, client: _api(configStatus: 404), storefrontId: 'sf');

      expect(find.byKey(const Key('player')), findsOneWidget);
      expect(_view(tester).options, const PlayerOptions());
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without a configId nothing is fetched or changed', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await _pump(
        tester,
        client: _api(requests: requests),
        configId: null,
        storefrontId: 'sf',
      );

      expect(
        requests.where((r) => r.url.path.contains('player-configs')),
        isEmpty,
      );
      expect(_view(tester).options, const PlayerOptions());
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('chromecast: false turns casting off', (tester) async {
      final backend = await _pump(
        tester,
        client: _api(config: _config(chromecast: false)),
        storefrontId: 'sf',
        castReceiverAppId: 'ABCD1234',
      );

      expect(backend.scans, 0);
      expect(_view(tester).castAvailable, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the config receiver casts films without one in code', (
      tester,
    ) async {
      final backend = await _pump(
        tester,
        client: _api(config: _config(receiver: 'CFG12345')),
        storefrontId: 'sf',
      );

      expect(_view(tester).castAvailable, isTrue);
      _view(tester).onCastRequested!(Duration.zero);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();
      expect(backend.appId, 'CFG12345');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a receiver in code wins over the config', (tester) async {
      final backend = await _pump(
        tester,
        client: _api(config: _config(receiver: 'CFG12345')),
        storefrontId: 'sf',
        castReceiverAppId: 'CODE1234',
      );

      _view(tester).onCastRequested!(Duration.zero);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();
      expect(backend.appId, 'CODE1234');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the default player builder', () {
    const options = PlayerOptions(loop: true, captions: false);
    final target = VideoplayerSourceTarget(
      EyzflowSource(
        id: 's',
        title: 'Film',
        sourceType: const EyzflowFilm('cat'),
      ),
    );

    testWidgets('gives the options to each route', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      );
      final tizen = buildDefaultVideoplayerPlayer(
        context,
        target,
        operatingSystem: 'tizen',
        isTv: true,
        options: options,
      );
      expect((tizen as TizenAvplayPlayer).options, options);
      final androidTv = buildDefaultVideoplayerPlayer(
        context,
        target,
        operatingSystem: 'android',
        isTv: true,
        options: options,
      );
      expect((androidTv as SystemVideoPlayer).options, options);
      expect(androidTv.useSharedOverlay, isTrue);
      final phone = buildDefaultVideoplayerPlayer(
        context,
        target,
        operatingSystem: 'android',
        options: options,
      );
      expect((phone as SystemVideoPlayer).options, options);
    });
  });

  group('the TV overlay', () {
    PlayerControlsBloc bloc0(
      _Playback p, {
      bool hidesWhenIdle = true,
      bool captions = true,
    }) {
      final bloc = PlayerControlsBloc(
        controller: p,
        tracks: p,
        autoHide: const Duration(seconds: 4),
        hidesWhenIdle: hidesWhenIdle,
        captions: captions,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    Widget harness(
      PlayerControlsBloc bloc, {
      PlayerControlsTheme theme = const PlayerControlsTheme(),
      bool showControls = true,
      VoidCallback? onBack,
    }) => MaterialApp(
      home: Scaffold(
        body: BlocProvider<PlayerControlsBloc>.value(
          value: bloc,
          child: PlayerControls(
            title: 'Film A',
            onBack: onBack,
            theme: theme,
            showControls: showControls,
          ),
        ),
      ),
    );

    BoxDecoration disc(WidgetTester tester, String key) =>
        tester
                .widget<AnimatedContainer>(
                  find.descendant(
                    of: find.byKey(Key(key)),
                    matching: find.byType(AnimatedContainer),
                  ),
                )
                .decoration!
            as BoxDecoration;

    testWidgets('draws the config theme', (tester) async {
      final theme = PlayerControlsTheme.fromPlayerTheme(
        PlayerConfig.fromJson(_config()).theme,
      );
      final bloc = bloc0(_Playback());
      await tester.pumpWidget(harness(bloc, theme: theme));
      await tester.pump();

      // Focus starts on play/pause: its disc is the accent.
      expect(disc(tester, 'player_controls_play_pause').color, _red);
      expect(
        tester.widget<Text>(find.text('Film A')).style!.color,
        const Color(0xFFEEEEEE),
      );
      // The progress bar is the accent too.
      final slider = tester.widget<SliderTheme>(
        find.descendant(
          of: find.byKey(const Key('player_controls_progress')),
          matching: find.byType(SliderTheme),
        ),
      );
      expect(slider.data.activeTrackColor, _red);
      expect(slider.data.thumbColor, _red);
      // The shade at the bottom is the bar colour.
      final shade = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((b) => b.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.gradient != null);
      expect(
        (shade.gradient! as LinearGradient).colors.last,
        const Color.fromARGB(128, 0, 0, 0),
      );

      // Down to the progress bar: its focus box takes the radius.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 200));
      final progress = tester.widget<AnimatedContainer>(
        find.byKey(const Key('player_controls_progress')),
      );
      final box = progress.decoration! as BoxDecoration;
      expect(box.borderRadius, BorderRadius.circular(10));
      expect(box.border, Border.all(color: _red, width: 2));
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('without a theme keeps its own look', (tester) async {
      final bloc = bloc0(_Playback());
      await tester.pumpWidget(harness(bloc));
      await tester.pump();

      expect(disc(tester, 'player_controls_play_pause').color, Colors.white);
      expect(find.byType(SliderTheme), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('autoHideControls: false keeps it up', (tester) async {
      final bloc = bloc0(_Playback(), hidesWhenIdle: false);
      await tester.pumpWidget(harness(bloc));
      await tester.pump();
      bloc.add(const PlayerControlsActivity());
      await tester.pump(const Duration(seconds: 10));
      expect(bloc.state.visible, isTrue);
    });

    testWidgets('captions: false offers and plays no subtitles', (
      tester,
    ) async {
      final playback = _Playback()..selectedTextTrackId = 1;
      final bloc = bloc0(playback, captions: false);
      await tester.pumpWidget(harness(bloc));
      bloc.add(
        const PlayerControlsTracksLoaded(
          audioTracks: [PlayerAudioTrack(trackId: 1, language: 'de')],
          textTracks: [PlayerTextTrack(trackId: 1, language: 'de')],
        ),
      );
      await tester.pump();

      expect(bloc.state.textTracks, isEmpty);
      expect(bloc.state.selectedTextTrackId, isNull);
      expect(playback.textSelections, [null]);
      expect(find.byKey(const Key('player_controls_subtitles')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('controls: false shows nothing, the remote still works', (
      tester,
    ) async {
      final playback = _Playback();
      final bloc = bloc0(playback);
      var backs = 0;
      await tester.pumpWidget(
        harness(bloc, showControls: false, onBack: () => backs += 1),
      );
      await tester.pump();

      expect(find.text('Film A'), findsNothing);
      expect(find.byKey(const Key('player_controls_play_pause')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(playback.playCount, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      // A skip seeks once the burst is over.
      await tester.pump(kPlayerSkipCommitDelay);
      await tester.pump();
      expect(playback.seekTargets, isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(backs, 1);
      // Android TV's Back arrives as a route pop.
      await tester.binding.handlePopRoute();
      expect(backs, 2);
      await tester.pump(const Duration(seconds: 5));
    });
  });
}

final class _Playback implements VideoplaybackController, VideoplaybackTracks {
  int playCount = 0;
  final seekTargets = <Duration>[];
  final textSelections = <int?>[];

  @override
  VideoplaybackValue get value => const VideoplaybackValue();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> play() async => playCount++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async => seekTargets.add(position);
  @override
  void addListener(void Function(VideoplaybackValue) listener) {}
  @override
  void removeListener(void Function(VideoplaybackValue) listener) {}
  @override
  Future<void> dispose() async {}
  @override
  int? selectedAudioTrackId;
  @override
  int? selectedTextTrackId;
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async => const [];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const [];
  @override
  Future<bool> selectAudioTrack(int trackId) async => true;
  @override
  Future<bool> selectTextTrack(int? trackId) async {
    textSelections.add(trackId);
    selectedTextTrackId = trackId;
    return true;
  }
}
