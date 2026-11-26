import 'package:eyzflow_player/src/player/player_loading_indicator.dart';
import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/bloc/player_controls_bloc.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/player_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget _harness(
  PlayerControlsBloc bloc, {
  VoidCallback? onBack,
  Uri? thumbnailsUrl,
  ThumbnailLoader? thumbnailLoader,
}) => MaterialApp(
  home: Scaffold(
    body: BlocProvider<PlayerControlsBloc>.value(
      value: bloc,
      child: PlayerControls(
        title: 'Film A',
        onBack: onBack,
        thumbnailsUrl: thumbnailsUrl,
        thumbnailLoader: thumbnailLoader,
      ),
    ),
  ),
);

final _thumbnailsUrl = Uri.parse(
  'https://stream.eyzflow.com/s1/thumbnails/thumbnail.vtt',
);

/// A track with a tile every 15 s, three per sprite row.
ThumbnailLoader _thumbnailLoader() => ThumbnailLoader(
  client: MockClient(
    (_) async => http.Response(
      [
        'WEBVTT',
        for (var i = 0; i < 40; i++)
          '\n${_vttTime(i * 15)} --> ${_vttTime(i * 15 + 15)}\n'
              'thumb_${i ~/ 3}.jpg#xywh=${(i % 3) * 199},0,199,112',
      ].join('\n'),
      200,
    ),
  ),
);

String _vttTime(int seconds) =>
    '00:${(seconds ~/ 60).toString().padLeft(2, '0')}:'
    '${(seconds % 60).toString().padLeft(2, '0')}.000';

Finder _thumbnail(String key) => find.byKey(
  ValueKey<String>(
    'player_controls_thumbnail:https://stream.eyzflow.com/s1/thumbnails/$key',
  ),
);

Finder get _anyThumbnail => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(
        'player_controls_thumbnail:',
      ),
);

PlayerControlsBloc _bloc(_FakePlayback p) {
  final bloc = PlayerControlsBloc(
    controller: p,
    tracks: p,
    autoHide: const Duration(seconds: 30),
  );
  // Close in teardown, not in the test body: awaiting `bloc.close()` while a
  // `BlocBuilder` is (or was) listening hangs under the fake-async test binding
  // because the state stream's onDone never flushes inside the body.
  addTearDown(bloc.close);
  return bloc;
}

/// Which of the overlay's controls currently holds focus, by its debug label
/// — the row model names its nodes, so the walk reads as the viewer sees it.
String? focusedControl() => FocusManager.instance.primaryFocus?.debugLabel
    ?.replaceFirst('controls.', '');

/// Which track row holds focus, by its label.
///
/// The panel's rows are unnamed focus nodes, so [focusedControl] cannot see
/// them — but a focused row inverts to black-on-white, which is exactly what
/// the viewer uses to find it.
String? focusedRow(WidgetTester tester, List<String> labels) {
  for (final String label in labels) {
    final Finder finder = find.text(label);
    if (finder.evaluate().isEmpty) continue;
    if (tester.widget<Text>(finder).style?.color == Colors.black) return label;
  }
  return null;
}

/// Shows the player in German: track names come from its built-in table.
Future<void> _loadGermanNames() async => setEYZFlowPlayerLanguage('de');

/// Dispatches the tracks that put the audio and subtitle buttons on screen.
/// Each button hides when its panel would have nothing to offer, so a test
/// that walks the D-pad onto that row has to load some first.
void _loadTracks(PlayerControlsBloc bloc) => bloc.add(
  const PlayerControlsTracksLoaded(
    audioTracks: <PlayerAudioTrack>[
      PlayerAudioTrack(trackId: 1, language: 'de'),
    ],
    textTracks: <PlayerTextTrack>[PlayerTextTrack(trackId: 1, language: 'de')],
  ),
);

void main() {
  // Static tables, so a test that loads them would otherwise change what the
  // tests after it render.
  setUp(() => setEYZFlowPlayerLanguage('en'));
  tearDown(() => setEYZFlowPlayerLanguage(null));

  group('captions', () {
    const Key caption = Key('caption');
    late double inset;

    Widget captions(BuildContext context, double bottomInset) {
      inset = bottomInset;
      return Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: const Text('Hallo', key: caption),
        ),
      );
    }

    Widget harness(PlayerControlsBloc bloc, {bool showControls = true}) =>
        MaterialApp(
          home: Scaffold(
            body: BlocProvider<PlayerControlsBloc>.value(
              value: bloc,
              child: PlayerControls(
                title: 'Film A',
                showControls: showControls,
                captionsBuilder: captions,
              ),
            ),
          ),
        );

    testWidgets('stay above the bottom bar while the overlay shows', (
      tester,
    ) async {
      final bloc = _bloc(_FakePlayback());
      _loadTracks(bloc);
      await tester.pumpWidget(harness(bloc));
      // A frame for the bar's height to be reported, then the lift's ease.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(inset, greaterThan(0));
      final Rect text = tester.getRect(find.byKey(caption));
      expect(
        text.bottom,
        lessThanOrEqualTo(
          tester
              .getRect(find.byKey(const Key('player_controls_subtitles')))
              .top,
        ),
      );
      expect(
        text.bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(Slider)).top),
      );

      // Hidden, they drop back to the bottom.
      await tester.pump(const Duration(seconds: 31));
      await tester.pump(const Duration(milliseconds: 300));
      expect(inset, 0);
    });

    testWidgets('are drawn, unlifted, with controls off', (tester) async {
      final bloc = _bloc(_FakePlayback());
      await tester.pumpWidget(harness(bloc, showControls: false));
      await tester.pump();

      expect(find.byKey(caption), findsOneWidget);
      expect(inset, 0);
    });
  });

  testWidgets('renders transport controls and the title', (tester) async {
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(find.text('Film A'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    // The skip-back button legitimately renders replay_10 (closest glyph to a
    // 15 s step; see the widget's comment).
    expect(find.byIcon(Icons.replay_10), findsOneWidget);
    expect(find.byKey(const Key('player_controls_skip_back')), findsOneWidget);
    expect(
      find.byKey(const Key('player_controls_skip_forward')),
      findsOneWidget,
    );
    // The play/pause control takes focus on the first frame, which arms the
    // auto-hide timer; drain it so none is pending at teardown.
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('tapping play/pause dispatches a toggle', (tester) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration.zero,
        duration: Duration(seconds: 20),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(find.byIcon(Icons.pause), findsOneWidget);
    await tester.tap(find.byKey(const Key('player_controls_play_pause')));
    await tester.pump();
    expect(p.pauseCount, 1);
    // The toggle restarts the auto-hide timer; advance past it so no FakeTimer
    // is left pending when the test ends.
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('opening the subtitle panel lists tracks and an Off row', (
    tester,
  ) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
          PlayerTextTrack(trackId: 2, language: 'en'),
        ],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_subtitles')));
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsOneWidget);
    // Named from the player's built-in table, in its language (English).
    expect(find.text('German'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the audio panel localizes languages, drops undetermined ones, '
      'checks only what is playing, and offers no Off row', (tester) async {
    await _loadGermanNames();
    // What the plugin reports as playing, which is the only thing that says
    // so on Tizen: the AVPlay track list carries no selection flag.
    final p = _FakePlayback()..selectedAudioTrackId = 2;
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        // Three-letter codes: EYZFlow's stream-level audio languages are the
        // one catalogue field that carries them.
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'eng'),
          PlayerAudioTrack(trackId: 2, language: 'deu'),
          PlayerAudioTrack(trackId: 3, language: 'und'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_audio')));
    await tester.pumpAndSettle();

    expect(find.text('Englisch'), findsOneWidget);
    expect(find.text('Deutsch'), findsOneWidget);
    expect(find.text('und'), findsNothing);
    expect(find.text('Off'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the panel opens with focus on the language that is playing', (
    tester,
  ) async {
    await _loadGermanNames();
    final p = _FakePlayback()..selectedAudioTrackId = 2;
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'eng'),
          PlayerAudioTrack(trackId: 2, language: 'deu'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_audio')));
    await tester.pumpAndSettle();

    expect(focusedRow(tester, <String>['Englisch', 'Deutsch']), 'Deutsch');
    // Focus is inside the sidebar, not on the button that opened it.
    expect(focusedControl(), isNull);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the panel opens on its first row when nothing is playing', (
    tester,
  ) async {
    // An audio list whose active track the native player never reported. The
    // remote must still land somewhere.
    await _loadGermanNames();
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'eng'),
          PlayerAudioTrack(trackId: 2, language: 'deu'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_audio')));
    await tester.pumpAndSettle();

    expect(focusedRow(tester, <String>['Englisch', 'Deutsch']), 'Englisch');
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('an open panel keeps focus: arrows never leave the sidebar', (
    tester,
  ) async {
    await _loadGermanNames();
    final p = _FakePlayback()..selectedTextTrackId = 1;
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
          PlayerTextTrack(trackId: 2, language: 'en'),
        ],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_subtitles')));
    await tester.pumpAndSettle();
    // A German player: German track names and German "Off".
    const List<String> labels = <String>['Aus', 'Deutsch', 'Englisch'];
    expect(focusedRow(tester, labels), 'Deutsch');

    // Off the bottom, off the top, and sideways: every press either moves
    // within the rows or does nothing, and none of them reaches a control.
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowRight,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(focusedControl(), isNull);
      expect(focusedRow(tester, labels), isNotNull);
    }
    expect(focusedRow(tester, labels), 'Englisch');

    // Playback ticks rebuild the panel every frame on a real TV. The checked
    // row's autofocus must not keep yanking focus back off the row the
    // viewer has moved to.
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 3),
        duration: Duration(seconds: 90),
        isPlaying: true,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(focusedRow(tester, labels), 'Englisch');

    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusedControl(), isNull);
    }
    expect(focusedRow(tester, labels), 'Aus');
    // The overlay is still on its timer, panel and all.
    expect(bloc.state.visible, isTrue);
    await tester.pump(const Duration(seconds: 31));
    expect(bloc.state.visible, isFalse);
  });

  testWidgets('OK on the checked row closes the panel without reselecting', (
    tester,
  ) async {
    await _loadGermanNames();
    final p = _FakePlayback()..selectedTextTrackId = 1;
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_subtitles')));
    await tester.pumpAndSettle();
    expect(focusedRow(tester, <String>['Off', 'Deutsch']), 'Deutsch');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(bloc.state.activePanel, PlayerPanel.none);
    expect(bloc.state.selectedTextTrackId, 1);
    expect(p.textSelections, isEmpty);
    // Focus comes back to the button that opened it.
    expect(focusedControl(), 'subtitles');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the subtitle panel checks Off when nothing is playing', (
    tester,
  ) async {
    await _loadGermanNames();
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.tap(find.byKey(const Key('player_controls_subtitles')));
    await tester.pumpAndSettle();

    expect(find.text('Aus'), findsOneWidget);
    expect(find.text('Deutsch'), findsOneWidget);
    expect(bloc.state.selectedTextTrackId, isNull);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a button is hidden when its panel would have nothing to offer', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsTracksLoaded(
        // Every code names no determinate language, so no row could render.
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'und'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(find.byKey(const Key('player_controls_audio')), findsNothing);
    expect(find.byKey(const Key('player_controls_subtitles')), findsNothing);
    // And the D-pad skips the row rather than landing on a button that is not
    // there — focusing a detached node loses focus outright.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'progress');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a single language still shows its button, alone on the row', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[
          PlayerAudioTrack(trackId: 1, language: 'de'),
        ],
        textTracks: <PlayerTextTrack>[],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(find.byKey(const Key('player_controls_audio')), findsOneWidget);
    expect(find.byKey(const Key('player_controls_subtitles')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'audio');
    // Right would have walked onto the subtitles button that is not there.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(focusedControl(), 'audio');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a control takes focus on first frame, arming auto-hide', (
    tester,
  ) async {
    // The symptom of a wrapper that steals primary focus: no control ever
    // reports onFocused, so nothing dispatches Activity, so the auto-hide
    // timer never arms and the overlay sits over the video forever.
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(bloc.state.visible, isTrue);
    await tester.pump(const Duration(seconds: 31));
    expect(bloc.state.visible, isFalse);
  });

  testWidgets('a hidden overlay wakes on an arrow without scrubbing', (
    tester,
  ) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    bloc.add(const PlayerControlsHideRequested());
    await tester.pump();
    await tester.pump();
    expect(bloc.state.visible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();

    // Scrubbing belongs to the progress bar: the arrow only brings the
    // overlay back, on the transport.
    expect(p.seekTargets, isEmpty);
    expect(bloc.state.visible, isTrue);
    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a drag produces exactly one seek', (tester) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration.zero,
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    final Offset start = tester.getCenter(find.byType(Slider));
    final TestGesture gesture = await tester.startGesture(start);
    // Several intermediate positions, as a real drag produces.
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(p.seekTargets, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('down walks transport -> tracks -> progress, up walks back', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    _loadTracks(bloc);
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    expect(focusedControl(), 'playPause');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'audio');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'progress');

    // The bottom row is the end of the line — focus must not fall off it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'progress');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedControl(), 'audio');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedControl(), 'playPause');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedControl(), 'back');

    // And not off the top either.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedControl(), 'back');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('left and right move within the transport row only', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(focusedControl(), 'skipForward');

    // Off the end of the row, focus stays put rather than jumping rows.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(focusedControl(), 'skipForward');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('arrows on the progress row scrub', (tester) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'progress');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // The bar moves at once; the seek waits for the burst to end.
    expect(bloc.state.position, const Duration(seconds: 75));
    expect(p.seekTargets, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(kPlayerSkipCommitDelay);
    await tester.pump();
    expect(p.seekTargets, <Duration>[const Duration(seconds: 90)]);
    expect(focusedControl(), 'progress');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('OK on the progress row toggles play/pause', (tester) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'progress');

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(p.pauseCount, 1);
    expect(p.playCount, 0);
    expect(focusedControl(), 'progress');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('OK on the progress row seeks a skip preview at once', (
    tester,
  ) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(p.seekTargets, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(p.seekTargets, <Duration>[const Duration(seconds: 90)]);
    expect(p.pauseCount, 0);
    expect(p.playCount, 0);

    await tester.pump(kPlayerSkipCommitDelay);
    await tester.pump();
    expect(p.seekTargets, hasLength(1));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('a skip preview shows the thumbnail of where it will seek', (
    tester,
  ) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(
      _harness(
        bloc,
        thumbnailsUrl: _thumbnailsUrl,
        thumbnailLoader: _thumbnailLoader(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_anyThumbnail, findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // 75 s: the sixth tile, the third in its sprite.
    expect(_thumbnail('thumb_1.jpg#398,0'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    // 90 s: the seventh tile, the first of the next sprite.
    expect(_thumbnail('thumb_2.jpg#0,0'), findsOneWidget);

    // Once the seek is sent, the preview is over.
    await tester.pump(kPlayerSkipCommitDelay);
    await tester.pump();
    expect(p.seekTargets, <Duration>[const Duration(seconds: 90)]);
    expect(_anyThumbnail, findsNothing);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('without a thumbnail track a skip shows no thumbnail', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(seconds: 60),
        duration: Duration(seconds: 600),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(
      _harness(
        bloc,
        thumbnailsUrl: _thumbnailsUrl,
        thumbnailLoader: ThumbnailLoader(
          client: MockClient((_) async => http.Response('', 404)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    bloc.add(const PlayerControlsSkipBy(1));
    await tester.pump();
    expect(bloc.state.isPreviewing, isTrue);
    expect(_anyThumbnail, findsNothing);
    await tester.pump(kPlayerSkipCommitDelay);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('focus landing nowhere is pulled back to a control', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    _loadTracks(bloc);
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'audio');

    // What a removed or rebuilt control leaves behind: primary focus falls
    // to the enclosing scope, so no control is lit and the remote looks dead.
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    await tester.pump();

    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('reappearing resets focus to play/pause', (tester) async {
    final bloc = _bloc(_FakePlayback());
    _loadTracks(bloc);
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'audio');

    bloc.add(const PlayerControlsHideRequested());
    await tester.pump();
    await tester.pump();
    expect(bloc.state.visible, isFalse);

    bloc.add(const PlayerControlsActivity());
    await tester.pump();
    await tester.pump();
    expect(bloc.state.visible, isTrue);
    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('closing a track panel returns focus to the button that opened '
      'it', (tester) async {
    final p = _FakePlayback();
    final bloc = _bloc(p);
    bloc.add(
      const PlayerControlsTracksLoaded(
        audioTracks: <PlayerAudioTrack>[],
        textTracks: <PlayerTextTrack>[
          PlayerTextTrack(trackId: 1, language: 'de'),
        ],
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.subtitles));
    await tester.pump();
    await tester.pump();

    bloc.add(const PlayerControlsPanelClosed());
    await tester.pump();
    await tester.pump();

    // Without the restore this is null: the panel's rows held focus and left
    // the tree with it.
    expect(focusedControl(), 'subtitles');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the system back button closes an open panel, not the player', (
    tester,
  ) async {
    var backs = 0;
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc, onBack: () => backs++));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
    await tester.pump();
    await tester.pump();

    // What Android delivers for Back: a route pop, never a key event.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();

    expect(bloc.state.activePanel, PlayerPanel.none);
    expect(bloc.state.visible, isTrue);
    expect(backs, 0);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the system back button walks panel, overlay, then player', (
    tester,
  ) async {
    var backs = 0;
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc, onBack: () => backs++));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.subtitles));
    await tester.pump();
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(bloc.state.activePanel, PlayerPanel.none, reason: 'panel first');
    expect(backs, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();
    expect(bloc.state.visible, isFalse, reason: 'then the overlay');
    expect(backs, 0);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(backs, 1, reason: 'only then the player');
  });

  testWidgets('hiding the overlay closes any open panel', (tester) async {
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.activePanel, PlayerPanel.audio);

    bloc.add(const PlayerControlsHideRequested());
    await tester.pump();
    await tester.pump();

    // Reappearing must be a clean slate, not a half-open menu.
    expect(bloc.state.visible, isFalse);
    expect(bloc.state.activePanel, PlayerPanel.none);

    bloc.add(const PlayerControlsActivity());
    await tester.pump();
    await tester.pump();
    expect(bloc.state.activePanel, PlayerPanel.none);
    expect(focusedControl(), 'playPause');
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('one Android TV Back press takes exactly one rung', (
    tester,
  ) async {
    var backs = 0;
    final bloc = _bloc(_FakePlayback());
    _loadTracks(bloc);
    await tester.pumpWidget(_harness(bloc, onBack: () => backs++));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.audio));
    await tester.pump();
    await tester.pump();

    // Android TV delivers a single press both ways, with no frame between.
    // `escape` stands in for `goBack`, which has no simulatable physical key;
    // the handler treats the two identically.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump();

    expect(bloc.state.activePanel, PlayerPanel.none, reason: 'panel closed');
    expect(bloc.state.visible, isTrue, reason: 'overlay must stay up');
    expect(focusedControl(), 'audio', reason: 'focus returns to the opener');
    expect(backs, 0);
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('an idle timeout over an open panel closes it and resets focus', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    bloc.add(const PlayerControlsPanelOpened(PlayerPanel.subtitles));
    await tester.pump();
    await tester.pump();
    expect(bloc.state.activePanel, PlayerPanel.subtitles);

    // The countdown keeps running under the panel (the harness uses 30 s).
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();

    expect(bloc.state.visible, isFalse);
    expect(bloc.state.activePanel, PlayerPanel.none);
    expect(focusedControl(), 'playPause');
  });

  testWidgets('the buffering spinner sits beside the elapsed time', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(minutes: 3),
        duration: Duration(minutes: 90),
        isPlaying: true,
      ),
    );
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);

    bloc.add(const PlayerControlsBufferingChanged(true));
    await tester.pump();
    await tester.pump();

    final Offset spinner = tester.getCenter(
      find.byType(CircularProgressIndicator),
    );
    final Offset elapsed = tester.getCenter(find.text('03:00'));
    final Offset playPause = tester.getCenter(
      find.byKey(const Key('player_controls_play_pause')),
    );

    // Beside the elapsed time, down in the bottom bar — not over the
    // transport, where it used to sit.
    expect((spinner.dy - elapsed.dy).abs(), lessThan(8));
    expect(spinner.dx, greaterThan(elapsed.dx));
    expect(spinner.dy, greaterThan(playPause.dy + 100));
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('the focus reset waits for the overlay to finish fading', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    _loadTracks(bloc);
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedControl(), 'audio');

    bloc.add(const PlayerControlsHideRequested());
    await tester.pump();
    await tester.pump();
    expect(bloc.state.visible, isFalse);

    // Mid-fade the overlay is still on screen: moving focus now would show
    // the halo jumping across it.
    await tester.pump(const Duration(milliseconds: 100));
    expect(focusedControl(), 'audio');

    await tester.pump(const Duration(milliseconds: 200));
    expect(focusedControl(), 'playPause');
  });

  testWidgets('buffering centres the spinner only once the overlay is gone', (
    tester,
  ) async {
    final bloc = _bloc(_FakePlayback());
    bloc.add(
      const PlayerControlsValueTicked(
        position: Duration(minutes: 3),
        duration: Duration(minutes: 90),
        isPlaying: true,
      ),
    );
    bloc.add(const PlayerControlsBufferingChanged(true));
    await tester.pumpWidget(_harness(bloc));
    await tester.pump();

    final double middle = tester.getCenter(find.byType(PlayerControls)).dy;

    // Visible: one spinner, down beside the elapsed time.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.getCenter(find.byType(CircularProgressIndicator)).dy,
      greaterThan(middle),
    );

    bloc.add(const PlayerControlsHideRequested());
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Hidden: a centred one takes over, since there is no elapsed time on
    // screen to sit beside.
    expect(find.byType(PlayerLoadingIndicator), findsOneWidget);
    expect(
      (tester.getCenter(find.byType(PlayerLoadingIndicator)).dy - middle).abs(),
      lessThan(4),
      reason: 'a spinner must sit in the centre while the overlay is hidden',
    );
  });
}

final class _FakePlayback
    implements VideoplaybackController, VideoplaybackTracks {
  int playCount = 0;
  int pauseCount = 0;

  @override
  VideoplaybackValue get value => const VideoplaybackValue();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> play() async => playCount++;
  @override
  Future<void> pause() async => pauseCount++;
  final List<Duration> seekTargets = <Duration>[];

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
  Future<List<PlayerAudioTrack>> audioTracks() async =>
      const <PlayerAudioTrack>[];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const <PlayerTextTrack>[];
  final List<int> audioSelections = <int>[];
  final List<int?> textSelections = <int?>[];

  @override
  Future<bool> selectAudioTrack(int trackId) async {
    audioSelections.add(trackId);
    return true;
  }

  @override
  Future<bool> selectTextTrack(int? trackId) async {
    textSelections.add(trackId);
    return true;
  }
}
