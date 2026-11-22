import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/videoplayer_feature_bloc.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/tizen_avplay_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const VideoplayerTarget _film = VideoplayerTrailerTarget(
  EyzflowSource(id: 'film', title: 'Film'),
);

Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

final class _Content implements VideoplaybackController, VideoplaybackTracks {
  final List<void Function(VideoplaybackValue)> _listeners =
      <void Function(VideoplaybackValue)>[];
  final List<Duration> seeks = <Duration>[];
  VideoplaybackValue _value = const VideoplaybackValue();

  void tick(num seconds) {
    _value = VideoplaybackValue(
      position: _s(seconds),
      duration: const Duration(minutes: 10),
      isPlaying: true,
    );
    for (final listener in List.of(_listeners)) {
      listener(_value);
    }
  }

  @override
  VideoplaybackValue get value => _value;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);
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

Finder _button() => find.byKey(const ValueKey<String>('eyzflow-skip-signal'));

void main() {
  testWidgets('Tizen: with the controls hidden OK skips the recap', (
    tester,
  ) async {
    final _Content content = _Content();
    final List<PlaybackEvent> events = <PlaybackEvent>[];
    Uri? loadedFrom;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => VideoplayerFeatureBloc(target: _film),
            child: TizenAvplayPlayer(
              target: _film,
              createController: (_) async => content,
              onPlaybackEvent: events.add,
              loadSignals: (Uri master) async {
                loadedFrom = master;
                return <StreamSignal>[
                  StreamSignal(
                    id: 'eyz-recap',
                    type: StreamSignalType.recap,
                    start: _s(0),
                    end: _s(40),
                  ),
                ];
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(loadedFrom?.path, '/film/master.m3u8');

    content.tick(3);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Skip recap'), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'controls.skipSignal',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(content.seeks, <Duration>[_s(40)]);
    expect(_button(), findsNothing);
    expect(
      events
          .where((e) => e is PlaybackSignalStarted || e is PlaybackSignalEnded)
          .map((e) => e.runtimeType),
      <Type>[PlaybackSignalStarted, PlaybackSignalEnded],
    );
    await tester.pumpWidget(const SizedBox());
  });
}
