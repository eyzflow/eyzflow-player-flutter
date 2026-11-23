import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/ads/ad_breaks.dart';
import 'package:eyzflow_player/src/ads/vast.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';
import 'package:eyzflow_player/src/player/tv_ad_layer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_ad_player.dart';

const VideoplayerTarget _film = VideoplayerTrailerTarget(
  EyzflowSource(id: 'film', title: 'Film'),
);
const String _tag = 'https://ads.example/tag';

final class _Content implements VideoplaybackController, VideoplaybackTracks {
  final List<void Function(VideoplaybackValue)> _listeners =
      <void Function(VideoplaybackValue)>[];
  var playCount = 0;
  var initializeCount = 0;
  var pauseCount = 0;
  VideoplaybackValue _value = const VideoplaybackValue();

  void tick(num seconds, {bool completed = false}) {
    _value = VideoplaybackValue(
      position: Duration(milliseconds: (seconds * 1000).round()),
      duration: const Duration(minutes: 10),
      isPlaying: !completed,
      isCompleted: completed,
    );
    for (final listener in List.of(_listeners)) {
      listener(_value);
    }
  }

  @override
  VideoplaybackValue get value => _value;
  @override
  Future<void> initialize() async => initializeCount++;
  @override
  Future<void> play() async => playCount++;
  @override
  Future<void> pause() async => pauseCount++;
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  void addListener(void Function(VideoplaybackValue) listener) =>
      _listeners.add(listener);
  @override
  void removeListener(void Function(VideoplaybackValue) listener) =>
      _listeners.remove(listener);
  @override
  Future<void> dispose() async {}
  @override
  int? selectedAudioTrackId;
  @override
  int? selectedTextTrackId;
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async =>
      const <PlayerAudioTrack>[];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const <PlayerTextTrack>[];
  @override
  Future<bool> selectAudioTrack(int trackId) async => true;
  @override
  Future<bool> selectTextTrack(int? trackId) async => true;
}

final class _Fixture {
  _Fixture(
    this.tester, {
    required String tagBody,
    this.markers = const <int>[],
    this.withAds = true,
  }) : pages = <String, String>{_tag: tagBody};

  final WidgetTester tester;
  final Map<String, String> pages;
  final List<int> markers;
  final bool withAds;
  final _Content content = _Content();
  final List<FakeAdPlayer> players = <FakeAdPlayer>[];
  final List<Uri> requests = <Uri>[];
  final List<PlaybackEvent> events = <PlaybackEvent>[];

  FakeAdPlayer get ad => players.last;

  Future<void> mount() async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => VideoplayerFeatureBloc(target: _film),
            child: TizenAvplayPlayer(
              target: _film,
              createController: (_) async => content,
              onPlaybackEvent: events.add,
              options: PlayerOptions(
                ads: withAds ? PlayerAds(adTagUrl: _tag) : null,
              ),
              adClient: MockClient((http.Request request) async {
                requests.add(request.url);
                final String? body = pages[request.url.toString()];
                return body == null
                    ? http.Response('', 404)
                    : http.Response(body, 200);
              }),
              createAdPlayer: (VastMediaFile media) {
                final FakeAdPlayer player = FakeAdPlayer(media);
                players.add(player);
                return player;
              },
              loadAdBreaks: (Uri master) async => <AdBreak>[
                for (final int s in markers)
                  AdBreak(
                    id: 'eyz-ad-$s',
                    start: Duration(seconds: s),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  /// The content plays from [from] to [to] seconds.
  Future<void> play(int from, int to) async {
    for (var s = from * 2; s <= to * 2; s++) {
      content.tick(s / 2);
      await tester.pump();
    }
    await settle();
  }

  bool get controlsVisible => tester
      .widget<Visibility>(
        find.ancestor(
          of: find.byType(PlayerControls, skipOffstage: false),
          matching: find.byType(Visibility, skipOffstage: false),
        ),
      )
      .visible;

  Future<void> unmount() async {
    await tester.pumpWidget(const SizedBox());
    await settle();
  }
}

void main() {
  testWidgets('without ads in the config nothing is requested', (tester) async {
    final _Fixture f = _Fixture(
      tester,
      tagBody: vastOf(vastAd()),
      withAds: false,
    );
    await f.mount();
    expect(f.requests, isEmpty);
    expect(f.content.playCount, 1);
    expect(find.byType(TvAdLayer), findsNothing);
  });

  testWidgets('a pre-roll plays before the film player is created', (
    tester,
  ) async {
    final _Fixture f = _Fixture(tester, tagBody: vastOf(vastAd()));
    await f.mount();

    expect(f.content.initializeCount, 0, reason: 'the ad has the decoder');
    expect(f.players, hasLength(1));
    f.ad.advance(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('Ad 1 of 1 · 0:07'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('eyzflow-ad-skip')), findsNothing);
    expect(
      f.requests.map((Uri u) => u.path),
      containsAll(<String>['/tag', '/imp/a', '/start/a']),
    );

    f.ad.complete();
    await f.settle();
    expect(f.content.initializeCount, 1);
    expect(f.content.playCount, 1);
    expect(find.text('Ad 1 of 1 · 0:07'), findsNothing);
    expect(find.byType(PlayerControls), findsOneWidget);
    expect(f.controlsVisible, isTrue);
    expect(f.events.map((PlaybackEvent e) => e.runtimeType).take(3), <Type>[
      PlaybackAdBreakStarted,
      PlaybackAdBreakEnded,
      PlaybackReady,
    ]);
    await f.unmount();
  });

  testWidgets('a mid-roll at a marker pauses the film, hides the controls, '
      'and resumes it', (tester) async {
    final _Fixture f = _Fixture(
      tester,
      tagBody: vastOf(vastAd(id: 'm')),
      markers: const <int>[8],
    );
    await f.mount();
    expect(f.players, isEmpty, reason: 'no marker at 0: no pre-roll');
    expect(f.content.playCount, 1);

    await f.play(0, 9);
    expect(f.content.pauseCount, 1);
    expect(f.players, hasLength(1));
    expect(f.controlsVisible, isFalse);

    f.ad.advance(const Duration(seconds: 1));
    f.ad.complete();
    await f.settle();
    expect(f.content.playCount, 2);
    expect(f.controlsVisible, isTrue);
    await f.unmount();
  });

  testWidgets('the countdown shows before a mid-roll', (tester) async {
    final _Fixture f = _Fixture(
      tester,
      tagBody: vastOf(vastAd()),
      markers: const <int>[20],
    );
    await f.mount();
    await f.play(0, 16);
    expect(find.text('Ad in 4'), findsOneWidget);
    await f.unmount();
  });

  testWidgets('OK on the remote skips a skippable ad once allowed', (
    tester,
  ) async {
    final _Fixture f = _Fixture(
      tester,
      tagBody: vastOf(vastAd(skip: ' skipoffset="00:00:05"')),
    );
    await f.mount();
    f.ad.advance(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Skip in 3'), findsOneWidget);

    f.ad.advance(const Duration(seconds: 6));
    await f.settle();
    expect(find.text('Skip ad'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await f.settle();
    expect(f.requests.map((Uri u) => u.path), contains('/skip/a'));
    expect(f.content.initializeCount, 1);
    await f.unmount();
  });

  testWidgets('a VMAP post-roll plays before the player closes', (
    tester,
  ) async {
    final _Fixture f = _Fixture(
      tester,
      tagBody: vmapOf(<String, String>{'end': 'https://ads.example/post'}),
    );
    f.pages['https://ads.example/post'] = vastOf(vastAd(id: 'post'));
    await f.mount();
    expect(f.players, isEmpty);
    expect(f.content.playCount, 1);

    f.content.tick(600, completed: true);
    await f.settle();
    expect(f.players, hasLength(1));
    final VideoplayerFeatureBloc bloc = tester
        .element(find.byType(TizenAvplayPlayer))
        .read<VideoplayerFeatureBloc>();
    final Object stateBefore = bloc.state;
    f.ad.complete();
    await f.settle();
    expect(bloc.state, isNot(stateBefore), reason: 'closes after the ad');
    await f.unmount();
  });
}
