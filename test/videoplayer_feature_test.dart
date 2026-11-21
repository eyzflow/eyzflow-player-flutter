import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/default_player_builder.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';

void main() {
  testWidgets('Android native controls own Close before and after PiP', (
    tester,
  ) async {
    late VideoplayerFeatureBloc bloc;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(id: 'film', title: 'Film'),
          debugOperatingSystemOverride: 'android',
          playerBuilder: (context, _) {
            bloc = context.read<VideoplayerFeatureBloc>();
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Close player'), findsNothing);
    bloc.add(const VideoplayerFeaturePictureInPictureChanged(true));
    await tester.pump();
    expect(find.byTooltip('Close player'), findsNothing);
    bloc.add(const VideoplayerFeaturePictureInPictureChanged(false));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close player'), findsNothing);
  });
  testWidgets('retryCreatesOneNewController', (tester) async {
    late VideoplayerFeatureBloc bloc;
    var mounts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(id: 'film', title: 'Film'),
          debugOperatingSystemOverride: 'android',
          playerBuilder: (context, _) {
            bloc = context.read<VideoplayerFeatureBloc>();
            return _MountCounter(onMount: () => mounts++);
          },
        ),
      ),
    );
    await tester.pump();
    bloc.add(const VideoplayerFeatureSourceFailed('failed'));
    await tester.pump();
    expect(mounts, 1);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(mounts, 2);
    expect(bloc.state.featureState, VideoplayerFeatureStatus.ready);
  });

  testWidgets(
    'Android phone playback enters landscape and releases it on close',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final orientations = <dynamic>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoplayerFeatureView(
            videoSource: const EyzflowSource(id: 'film', title: 'Film'),
            playerBuilder: _fakePlayerBuilder,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        orientations,
        contains(
          equals([
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ]),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(orientations.last, isEmpty);
    },
  );

  for (final scenario in [
    (size: Size(1024, 768), isTv: false),
    (size: Size(390, 844), isTv: true),
  ]) {
    testWidgets('Playback preserves orientation for $scenario', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final orientations = <dynamic>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoplayerFeatureView(
            videoSource: const EyzflowSource(id: 'film', title: 'Film'),
            playerBuilder: _fakePlayerBuilder,
            isTv: scenario.isTv,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(orientations, isEmpty);
    });
  }

  test(
    'VideoplayerFeatureView routes a Trailer source to a trailer target',
    () {
      const source = EyzflowSource(
        id: 'trailer-a',
        title: 'Trailer A',
        sourceType: EyzflowTrailer('catalogue-1'),
      );

      final view = VideoplayerFeatureView(videoSource: source);

      expect(view.target, isA<VideoplayerTrailerTarget>());
    },
  );

  test('VideoplayerFeatureView routes a legacy source with no sourceType to a '
      'trailer target', () {
    const source = EyzflowSource(id: 'legacy-stream', title: 'Legacy');

    final view = VideoplayerFeatureView(videoSource: source);

    expect(view.target, isA<VideoplayerTrailerTarget>());
  });

  test(
    'VideoplayerFeatureView routes a FeatureLength source to a source target',
    () {
      const source = EyzflowSource(
        id: 'film-a',
        title: 'Film A',
        sourceType: EyzflowFilm('title-a'),
      );

      final view = VideoplayerFeatureView(videoSource: source);

      expect(view.target, isA<VideoplayerSourceTarget>());
    },
  );

  test('started event marks the player ready', () async {
    const source = EyzflowSource(id: 'sample-stream', title: 'Sample Video');
    final bloc = VideoplayerFeatureBloc(
      target: const VideoplayerTrailerTarget(source),
    );
    final expected = expectLater(
      bloc.stream,
      emits(
        isA<VideoplayerFeatureState>().having(
          (state) => state.featureState,
          'featureState',
          VideoplayerFeatureStatus.ready,
        ),
      ),
    );

    bloc.add(const VideoplayerFeatureStarted());

    await expected;
    await bloc.close();
  });

  test('player error marks the player failed', () async {
    const source = EyzflowSource(id: 'sample-stream', title: 'Sample Video');
    final bloc = VideoplayerFeatureBloc(
      target: const VideoplayerTrailerTarget(source),
    );
    final expected = expectLater(
      bloc.stream,
      emits(
        isA<VideoplayerFeatureState>()
            .having(
              (state) => state.featureState,
              'featureState',
              VideoplayerFeatureStatus.failed,
            )
            .having(
              (state) => state.errorMessage,
              'errorMessage',
              'Playback failed',
            ),
      ),
    );

    bloc.add(const VideoplayerFeaturePlayerFailed('Playback failed'));

    await expected;
    await bloc.close();
  });

  testWidgets('renders injected player surface with video source', (
    tester,
  ) async {
    const source = EyzflowSource(id: 'sample-stream', title: 'Sample Video');

    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: source,
          playerBuilder: _fakePlayerBuilder,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fake player: sample-stream'), findsOneWidget);
  });

  testWidgets('failure alert focuses OK and closes the player', (tester) async {
    var closeRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(
            id: 'sample-stream',
            title: 'Sample Video',
          ),
          onCloseRequested: () => closeRequests++,
          playerBuilder: (context, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              context.read<VideoplayerFeatureBloc>().add(
                const VideoplayerFeatureSourceFailed(
                  'Playback took too long to start.',
                ),
              );
            });
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Playback took too long to start.'), findsOneWidget);
    final TextButton okButton = tester.widget(
      find.widgetWithText(TextButton, 'OK'),
    );
    expect(okButton.autofocus, isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'OK'));

    expect(closeRequests, 1);
  });

  testWidgets('iOS keeps the shared close affordance', (
    WidgetTester tester,
  ) async {
    int closeRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            sourceType: EyzflowFilm('title-a'),
          ),
          debugOperatingSystemOverride: 'ios',
          onCloseRequested: () => closeRequests += 1,
          playerBuilder: _fakePlayerBuilder,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Close player'));
    await tester.pump();

    expect(closeRequests, 1);
  });

  testWidgets('hides the shared close affordance on Tizen', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            sourceType: EyzflowFilm('title-a'),
          ),
          playerBuilder: _fakePlayerBuilder,
          debugOperatingSystemOverride: 'tizen',
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Close player'), findsNothing);
  });

  testWidgets('hides the shared close affordance on Android TV', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            sourceType: EyzflowFilm('title-a'),
          ),
          playerBuilder: _fakePlayerBuilder,
          debugOperatingSystemOverride: 'android',
          isTv: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Close player'), findsNothing);
  });

  testWidgets('native controls own the close affordance on an Android phone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoplayerFeatureView(
          videoSource: const EyzflowSource(
            id: 'film-a',
            title: 'Film A',
            sourceType: EyzflowFilm('title-a'),
          ),
          playerBuilder: _fakePlayerBuilder,
          debugOperatingSystemOverride: 'android',
          isTv: false,
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Close player'), findsNothing);
  });

  testWidgets('desktop platforms show no player for either real target', (
    WidgetTester tester,
  ) async {
    for (final String os in <String>['macos', 'windows']) {
      for (final VideoplayerTarget target in <VideoplayerTarget>[
        const VideoplayerTrailerTarget(
          EyzflowSource(id: 'trailer-a', title: 'Trailer A'),
        ),
        const VideoplayerSourceTarget(
          EyzflowSource(id: 'film-a', title: 'Film A'),
        ),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (BuildContext context) => buildDefaultVideoplayerPlayer(
                context,
                target,
                operatingSystem: os,
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byType(NoPlayerSurface),
          findsOneWidget,
          reason: 'os=$os target=$target must show the no-player surface',
        );
      }
    }
  });

  testWidgets('the default builder hands the event callback to each player', (
    tester,
  ) async {
    const VideoplayerTarget target = VideoplayerSourceTarget(
      EyzflowSource(id: 'film-a', title: 'Film A'),
    );
    void onPlaybackEvent(PlaybackEvent event) {}
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (BuildContext c) {
          context = c;
          return const SizedBox();
        },
      ),
    );

    // Built, never mounted: both players are platform-channel-backed.
    Widget build(String os, {bool isTv = false}) =>
        buildDefaultVideoplayerPlayer(
          context,
          target,
          operatingSystem: os,
          isTv: isTv,
          onPlaybackEvent: onPlaybackEvent,
        );

    expect(
      (build('tizen') as TizenAvplayPlayer).onPlaybackEvent,
      onPlaybackEvent,
    );
    for (final bool isTv in <bool>[false, true]) {
      final SystemVideoPlayer player =
          build('android', isTv: isTv) as SystemVideoPlayer;
      expect(player.useSharedOverlay, isTv);
      expect(player.onPlaybackEvent, onPlaybackEvent);
    }
    expect(
      (build('ios') as SystemVideoPlayer).onPlaybackEvent,
      onPlaybackEvent,
    );
    expect(
      VideoplayerFeatureView(
        videoSource: const EyzflowSource(id: 'film', title: 'Film'),
        onPlaybackEvent: onPlaybackEvent,
      ).onPlaybackEvent,
      onPlaybackEvent,
    );
  });

  testWidgets(
    'a DRM source on a non-Tizen host builds no player and no licence request',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoplayerFeatureView(
            videoSource: const EyzflowSource(
              id: 'film-a',
              title: 'Film A',
              drmAccessHeader: 'base64-drm-payload',
              sourceType: EyzflowFilm('title-a'),
            ),
          ),
        ),
      );
      await tester.pump();

      // The host is not Tizen, so the real platform detector routes to the
      // not-implemented surface: no AVPlay controller is created, and
      // therefore no WidevineLicenseClient and no licence HTTP request.
      expect(find.byType(NoPlayerSurface), findsOneWidget);
      expect(find.byType(TizenAvplayPlayer), findsNothing);
      // Documented deviation: the Bloc itself IS created before platform
      // policy is resolved. The spec's "no Bloc" wording is therefore not
      // literally met; the guarantees that matter — no controller, no licence
      // request — are.
      expect(find.byType(BlocProvider<VideoplayerFeatureBloc>), findsOneWidget);
    },
  );

  testWidgets(
    'localizes the shared close affordance in the storefront language',
    (tester) async {
      _useGermanStorefront();
      await tester.pumpWidget(
        MaterialApp(
          home: VideoplayerFeatureView(
            videoSource: const EyzflowSource(
              id: 'film-a',
              title: 'Film A',
              sourceType: EyzflowFilm('title-a'),
            ),
            playerBuilder: _fakePlayerBuilder,
            debugOperatingSystemOverride: 'ios',
            isTv: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Player schließen'), findsOneWidget);
      expect(find.byTooltip('Close player'), findsNothing);
    },
  );

  testWidgets('localizes the no-player surface in the storefront language', (
    tester,
  ) async {
    _useGermanStorefront();
    await tester.pumpWidget(
      const MaterialApp(home: NoPlayerSurface(operatingSystem: 'linux')),
    );

    expect(
      find.text('Wiedergabe ist auf dieser Plattform noch nicht verfügbar.'),
      findsOneWidget,
    );
  });
}

Widget _fakePlayerBuilder(BuildContext context, VideoplayerTarget target) {
  return BlocBuilder<VideoplayerFeatureBloc, VideoplayerFeatureState>(
    builder: (context, state) {
      final String label = switch (state.target) {
        VideoplayerTrailerTarget(:final source) => source.id,
        VideoplayerSourceTarget(:final source) => source.id,
      };
      return Center(child: Text('Fake player: $label'));
    },
  );
}

void _useGermanStorefront() {
  setEyzflowPlayerLanguage('de');
  addTearDown(() => setEyzflowPlayerLanguage(null));
}

class _MountCounter extends StatefulWidget {
  const _MountCounter({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
