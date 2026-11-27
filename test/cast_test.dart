import 'dart:async';
import 'dart:convert';

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_video_player.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:eyzflow_player/src/cast/casting_view.dart';
import 'package:eyzflow_player/src/player/track_panel.dart';
import 'package:eyzflow_player/src/native/cast.dart' as nvp;

const _tv = CastTarget(id: 'tv-1', name: 'Living Room TV', model: 'Chromecast');

/// A TV on the network that records what it was asked and reports what the
/// test tells it to.
final class _FakeTv implements CastConnection {
  final _playback = StreamController<CastPlayback>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final calls = <String>[];
  CastMedia? loaded;
  CastPlayback _current = const CastPlayback();

  void report(CastPlayback playback) {
    _current = playback;
    _playback.add(playback);
  }

  void refuse(String reason) => _errors.add(reason);

  void disconnect() => _playback.close();

  @override
  Stream<CastPlayback> get playback => _playback.stream;

  @override
  Stream<String> get errors => _errors.stream;

  @override
  CastPlayback get current => _current;

  @override
  Future<void> load(CastMedia media) async {
    loaded = media;
    calls.add('load');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => calls.add('seek $position');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setActiveTracks(List<int> trackIds) async =>
      calls.add('tracks $trackIds');

  @override
  Future<void> requestStatus() async => calls.add('status');
}

final class _FakeBackend implements CastBackend {
  List<CastTarget> devices = const [_tv];
  final tv = _FakeTv();
  String? appId;
  var scans = 0;
  var connects = 0;
  Object? connectError;

  /// Fails only the first connection, like a TV that restarted on a new port.
  Object? firstConnectError;

  @override
  Future<List<CastTarget>> discover({Duration? timeout}) async {
    scans += 1;
    return devices;
  }

  @override
  Future<CastConnection> connect(
    CastTarget target, {
    required String appId,
  }) async {
    this.appId = appId;
    connects += 1;
    final first = firstConnectError;
    if (first != null && connects == 1) throw first;
    if (connectError != null) throw connectError!;
    return tv;
  }
}

const _media = CastMedia(
  streamId: 's',
  contentUrl: 'https://stream.eyzflow.com/s/manifest.mpd',
  contentType: 'application/dash+xml',
  title: 'Film',
  startAt: Duration(minutes: 10),
);

Duration _min(int m) => Duration(minutes: m);

void main() {
  group('EYZFlowCastController', () {
    late _FakeBackend backend;
    late List<(CastEndReason, Duration)> ended;
    late List<CastPlayback> playbacks;
    late EYZFlowCastController cast;

    setUp(() {
      backend = _FakeBackend();
      ended = [];
      playbacks = [];
      cast = EYZFlowCastController(
        backend: backend,
        onPlayback: playbacks.add,
        onEnded: (reason, position) => ended.add((reason, position)),
      );
    });

    test('scans for TVs', () async {
      expect(cast.devices, isEmpty);
      await cast.scan();
      expect(cast.devices, [_tv]);
      expect(cast.scanning, isFalse);
    });

    test('a failed scan leaves no devices', () async {
      final failing = EYZFlowCastController(backend: _ThrowingBackend());
      await failing.scan();
      expect(failing.devices, isEmpty);
    });

    test('connects to the receiver, loads and reports the TV', () async {
      await cast.cast(_tv, _media, appId: 'ABCD1234');

      expect(backend.appId, 'ABCD1234');
      expect(backend.tv.loaded, same(_media));
      expect(cast.state, isA<CastConnecting>());

      backend.tv.report(
        CastPlayback(state: CastPlayerState.playing, position: _min(10)),
      );
      expect(cast.state, isA<CastActive>());
      expect(playbacks.single.position, _min(10));
    });

    test('stop ends at the TV position and stops the receiver', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(state: CastPlayerState.playing, position: _min(12)),
      );

      await cast.stop();

      expect(ended, [(CastEndReason.stopped, _min(12))]);
      expect(backend.tv.calls.last, 'stop');
      expect(cast.state, isA<CastOff>());
    });

    test('stop while connecting resumes where the phone was', () async {
      await cast.cast(_tv, _media, appId: 'A');
      await cast.stop();
      expect(ended, [(CastEndReason.stopped, _min(10))]);
    });

    test('the film ending on the TV is reported once', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(10),
          duration: _min(90),
        ),
      );
      backend.tv.report(
        CastPlayback(idleReason: 'FINISHED', duration: _min(90)),
      );
      backend.tv.disconnect();

      expect(ended, [(CastEndReason.finished, _min(90))]);
    });

    test('the TV closing the connection ends at its last position', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(state: CastPlayerState.paused, position: _min(20)),
      );
      backend.tv.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(ended, [(CastEndReason.disconnected, _min(20))]);
      expect(backend.tv.calls, isNot(contains('stop')));
    });

    test('a refused load fails, at the start position', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.refuse('LOAD_FAILED / 104');

      expect(ended, [(CastEndReason.failed, _min(10))]);
      expect(cast.state, isA<CastFailed>());
    });

    test('a connection that cannot be made fails', () async {
      backend.connectError = Exception('refused');
      await cast.cast(_tv, _media, appId: 'A');
      expect(ended.single.$1, CastEndReason.failed);
      expect(cast.isCasting, isFalse);
    });

    test('a refused address is looked up again and retried once', () async {
      backend.firstConnectError = Exception('Connection refused');
      await cast.cast(_tv, _media, appId: 'A');

      expect(backend.connects, 2);
      expect(backend.scans, 1);
      expect(cast.state, isA<CastConnecting>());
      expect(backend.tv.loaded, same(_media));
    });

    test('a refused receiver is not retried', () async {
      backend.connectError = StateError('Cast LAUNCH_ERROR: NOT_FOUND');
      await cast.cast(_tv, _media, appId: 'A');

      expect(backend.connects, 1);
      expect(ended.single.$1, CastEndReason.failed);
    });

    test('a TV that never starts playing fails after the load timeout', () {
      fakeAsync((async) {
        final slow = EYZFlowCastController(
          backend: backend,
          onEnded: (reason, position) => ended.add((reason, position)),
          loadTimeout: const Duration(seconds: 20),
        );
        slow.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(const CastPlayback(state: CastPlayerState.buffering));
        async.elapse(const Duration(seconds: 19));
        expect(ended, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(ended.single.$1, CastEndReason.failed);
      });
    });

    test('transport goes to the TV', () async {
      await cast.cast(_tv, _media, appId: 'A');
      await cast.pause();
      await cast.play();
      await cast.seek(_min(30));
      expect(backend.tv.calls, ['load', 'pause', 'play', 'seek ${_min(30)}']);
    });
  });

  group('cast clock', () {
    test('the position advances while the TV plays, not while paused', () {
      fakeAsync((async) {
        final backend = _FakeBackend();
        final reported = <Duration>[];
        final cast = EYZFlowCastController(
          backend: backend,
          onPlayback: (p) => reported.add(p.position),
        );
        cast.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(
          CastPlayback(state: CastPlayerState.playing, position: _min(10)),
        );
        async.elapse(const Duration(seconds: 3));
        expect(
          (cast.state as CastActive).playback.position,
          _min(10) + const Duration(seconds: 3),
        );
        expect(reported.last, _min(10) + const Duration(seconds: 3));

        backend.tv.report(
          CastPlayback(state: CastPlayerState.paused, position: _min(11)),
        );
        async.elapse(const Duration(seconds: 5));
        expect((cast.state as CastActive).playback.position, _min(11));
        cast.dispose();
      });
    });

    test('a pending seek freezes the clock until a receiver report', () {
      fakeAsync((async) {
        final backend = _FakeBackend();
        final positions = <Duration>[];
        final cast = EYZFlowCastController(
          backend: backend,
          onPlayback: (p) => positions.add(p.position),
        );
        cast.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(
          CastPlayback(state: CastPlayerState.playing, position: _min(1)),
        );
        async.elapse(const Duration(seconds: 1));
        final beforeSeek = positions.length;
        cast.seek(_min(20));
        async.elapse(const Duration(seconds: 16));
        expect(positions, hasLength(beforeSeek));
        expect(backend.tv.calls, contains('status'));
        backend.tv.report(
          CastPlayback(state: CastPlayerState.buffering, position: _min(20)),
        );
        async.elapse(const Duration(seconds: 3));
        expect(positions.last, _min(20));
        backend.tv.report(
          CastPlayback(state: CastPlayerState.playing, position: _min(20)),
        );
        async.elapse(const Duration(seconds: 2));
        expect(positions.last, _min(20) + const Duration(seconds: 2));
        cast.dispose();
      });
    });

    test('a status without a position cannot release a pending seek', () {
      fakeAsync((async) {
        final backend = _FakeBackend();
        final cast = EYZFlowCastController(backend: backend);
        cast.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(
          CastPlayback(state: CastPlayerState.playing, position: _min(1)),
        );
        async.elapse(const Duration(seconds: 2));
        final frozen = (cast.state as CastActive).playback.position;
        cast.seek(_min(10));
        backend.tv.report(
          CastPlayback(
            state: CastPlayerState.playing,
            position: _min(1),
            hasFreshPosition: false,
          ),
        );
        async.elapse(const Duration(seconds: 3));
        expect((cast.state as CastActive).playback.position, frozen);
        cast.dispose();
      });
    });

    test('the TV is asked for its status every 15 s while playing', () {
      fakeAsync((async) {
        final backend = _FakeBackend();
        final cast = EYZFlowCastController(backend: backend);
        cast.cast(_tv, _media, appId: 'A');
        async.flushMicrotasks();
        backend.tv.report(
          CastPlayback(state: CastPlayerState.playing, position: _min(1)),
        );
        async.elapse(const Duration(seconds: 31));
        expect(backend.tv.calls.where((c) => c == 'status'), hasLength(2));
        cast.dispose();
      });
    });
  });

  group('cast tracks', () {
    late _FakeBackend backend;
    late EYZFlowCastController cast;

    const tracks = <CastTrack>[
      CastTrack(id: 1, kind: CastTrackKind.audio, language: 'de'),
      CastTrack(id: 2, kind: CastTrackKind.audio, language: 'en'),
      CastTrack(id: 3, kind: CastTrackKind.subtitles, language: 'en-GB'),
      CastTrack(id: 4, kind: CastTrackKind.subtitles, language: 'de'),
    ];
    CastPlayback playing({List<int> active = const [1]}) => CastPlayback(
      state: CastPlayerState.playing,
      position: _min(1),
      tracks: tracks,
      activeTrackIds: active,
    );

    setUp(() {
      backend = _FakeBackend();
      cast = EYZFlowCastController(backend: backend);
    });

    test('the receiver status lists its audio and subtitle tracks', () {
      final status = nvp.castMediaTracks(<String, dynamic>{
        'tracks': [
          {'trackId': 1, 'type': 'AUDIO', 'language': 'de', 'name': 'Deutsch'},
          {'trackId': 3, 'type': 'TEXT', 'language': 'en'},
          {'trackId': 9, 'type': 'VIDEO'},
        ],
      })!;
      expect(status.map((t) => '${t.trackId} ${t.type} ${t.language}'), [
        '1 AUDIO de',
        '3 TEXT en',
        '9 VIDEO null',
      ]);
    });

    test(
      'the phone audio and subtitles carry over once, by language',
      () async {
        await cast.cast(
          _tv,
          _media,
          appId: 'A',
          audioLanguage: 'en',
          subtitleLanguage: 'en',
        );
        backend.tv.report(playing());
        backend.tv.report(playing(active: const [2, 3]));
        expect(backend.tv.calls.where((c) => c.startsWith('tracks')), [
          'tracks [2, 3]',
        ]);
      },
    );

    test('the phone tracks wait until the TV plays, since the receiver resets '
        'them when the film starts', () async {
      await cast.cast(
        _tv,
        _media,
        appId: 'A',
        audioLanguage: 'en',
        subtitleLanguage: 'de',
      );
      backend.tv.report(
        const CastPlayback(
          state: CastPlayerState.buffering,
          tracks: tracks,
          activeTrackIds: [1],
        ),
      );
      expect(backend.tv.calls.where((c) => c.startsWith('tracks')), isEmpty);
      backend.tv.report(playing());
      expect(backend.tv.calls.where((c) => c.startsWith('tracks')), [
        'tracks [2, 4]',
      ]);
    });

    test(
      'explicit Off reaches a receiver that has not reported active IDs',
      () async {
        await cast.cast(_tv, _media, appId: 'A');
        backend.tv.report(
          const CastPlayback(state: CastPlayerState.paused, tracks: tracks),
        );
        await cast.selectSubtitles(null);
        expect(backend.tv.calls.last, 'tracks []');
        cast.dispose();
      },
    );

    test(
      'partial native status distinguishes cached time and unknown tracks',
      () {
        final initial = const nvp.CastSessionStatus();
        final volume = initial.copyWith(volumeLevel: 0.5);
        expect(volume.hasFreshPosition, isFalse);
        expect(volume.hasActiveTrackIds, isFalse);
        final media = volume.copyWith(position: _min(4), activeTrackIds: []);
        expect(media.hasFreshPosition, isTrue);
        final trackEdit = media.copyWith(activeTrackIds: [42]);
        expect(trackEdit.hasFreshPosition, isFalse);
        expect(trackEdit.position, _min(4));
        expect(trackEdit.copyWith(muted: true).activeTrackIds, [42]);
        expect(media.copyWith(muted: true).hasActiveTrackIds, isTrue);
      },
    );

    test('no choice on the phone leaves the TV defaults', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(playing());
      expect(backend.tv.calls.where((c) => c.startsWith('tracks')), isEmpty);
    });

    test(
      'switching audio keeps the subtitles, and subtitles can go off',
      () async {
        await cast.cast(_tv, _media, appId: 'A');
        backend.tv.report(playing(active: const [1, 4]));
        await cast.selectAudio(2);
        backend.tv.report(playing(active: const [2, 4]));
        await cast.selectSubtitles(null);
        expect(backend.tv.calls.where((c) => c.startsWith('tracks')), [
          'tracks [2, 4]',
          'tracks [2]',
        ]);
      },
    );
  });

  group('forced subtitles on the TV', () {
    late _FakeBackend backend;
    late EYZFlowCastController cast;
    const tracks = <CastTrack>[
      CastTrack(id: 1, kind: CastTrackKind.audio, language: 'de'),
      CastTrack(id: 2, kind: CastTrackKind.audio, language: 'en'),
      CastTrack(id: 3, kind: CastTrackKind.subtitles, language: 'de'),
      CastTrack(
        id: 5,
        kind: CastTrackKind.subtitles,
        language: 'de',
        roles: ['forced-subtitle'],
      ),
      CastTrack(
        id: 6,
        kind: CastTrackKind.subtitles,
        language: 'en',
        roles: ['forced-subtitle'],
      ),
    ];
    CastPlayback playing(List<int> active) => CastPlayback(
      state: CastPlayerState.playing,
      position: _min(1),
      tracks: tracks,
      activeTrackIds: active,
    );
    List<String> trackCalls() =>
        backend.tv.calls.where((c) => c.startsWith('tracks')).toList();

    setUp(() {
      backend = _FakeBackend();
      cast = EYZFlowCastController(backend: backend);
    });

    test('a forced role marks the track forced', () {
      expect(tracks.map((t) => t.isForced), [false, false, false, true, true]);
    });

    test('Off plays the forced track in the audio\'s language', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(playing(const [1, 3]));
      await cast.selectSubtitles(null);
      expect(trackCalls(), ['tracks [1, 5]']);
    });

    test('with subtitles off, the forced track follows the audio', () async {
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(playing(const [1, 5]));
      await cast.selectAudio(2);
      expect(trackCalls(), ['tracks [2, 6]']);
    });

    test('the phone\'s Off carries over as the forced track', () async {
      await cast.cast(
        _tv,
        _media,
        appId: 'A',
        audioLanguage: 'de',
        subtitlesOff: true,
      );
      backend.tv.report(playing(const [1, 3]));
      expect(trackCalls(), ['tracks [1, 5]']);
    });

    test('a remembered language never picks a forced track', () async {
      await cast.cast(
        _tv,
        _media,
        appId: 'A',
        audioLanguage: 'en',
        subtitleLanguage: 'en',
      );
      backend.tv.report(playing(const [1]));
      expect(trackCalls(), ['tracks [2, 6]']);
    });
  });

  testWidgets('the casting screen offers the phone panels, labelled alike', (
    tester,
  ) async {
    final backend = _FakeBackend();
    final cast = EYZFlowCastController(backend: backend);
    await cast.cast(_tv, _media, appId: 'A');
    backend.tv.report(
      CastPlayback(
        state: CastPlayerState.paused,
        position: _min(1),
        duration: _min(90),
        tracks: const [
          CastTrack(
            id: 1,
            kind: CastTrackKind.audio,
            language: 'ar',
            name: 'Arabic stereo',
          ),
          CastTrack(
            id: 2,
            kind: CastTrackKind.audio,
            language: 'ar',
            name: 'Arabic 5.1 5.1',
          ),
          CastTrack(id: 4, kind: CastTrackKind.subtitles, language: 'de'),
        ],
        activeTrackIds: const [1, 4],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CastingView(cast: cast, title: 'Film', onClose: () {}),
      ),
    );

    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle();
    void expectPlainPanelText() {
      final labels = tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(TrackPanel),
          matching: find.byType(RichText),
        ),
      );
      expect(labels, isNotEmpty);
      for (final label in labels) {
        expect(
          label.text.style?.decoration?.contains(TextDecoration.underline),
          isNot(isTrue),
          reason: label.text.toPlainText(),
        );
      }
    }

    expectPlainPanelText();
    expect(find.text('Arabic'), findsOneWidget);
    await tester.tap(find.text('Arabic (5.1)'));
    await tester.pumpAndSettle();
    expect(backend.tv.calls.last, 'tracks [2, 4]');
    expect(find.text('Arabic (5.1)'), findsNothing);

    await tester.tap(find.text('Subtitles'));
    await tester.pumpAndSettle();
    expectPlainPanelText();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(backend.tv.calls.last, 'tracks [1]');
    cast.dispose();
  });

  testWidgets(
    'the remote focuses the selected track and Back returns to casting',
    (tester) async {
      final backend = _FakeBackend();
      final cast = EYZFlowCastController(backend: backend);
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(_receiverTracks(active: [2, 4]));
      await tester.pumpWidget(
        MaterialApp(
          home: CastingView(cast: cast, title: 'Film', onClose: () {}),
        ),
      );
      final button = tester.element(find.text('Audio'));
      Focus.of(button).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        Focus.of(tester.element(find.text('English'))).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        Focus.of(tester.element(find.text('French'))).hasPrimaryFocus,
        isTrue,
      );
      // Android supplies the logical Back keycode independently of the scan code.
      await tester.sendKeyEvent(
        LogicalKeyboardKey.goBack,
        physicalKey: PhysicalKeyboardKey.escape,
      );
      await tester.pumpAndSettle();
      expect(find.text('English'), findsNothing);
      expect(Focus.of(button).hasFocus, isTrue);
      expect(cast.isCasting, isTrue);
      expect(backend.tv.calls, ['load']);
      cast.dispose();
    },
  );

  testWidgets(
    'a long casting panel scrolls to the last track by touch and remote',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = _FakeBackend();
      final cast = EYZFlowCastController(backend: backend);
      await cast.cast(_tv, _media, appId: 'A');
      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.paused,
          tracks: [
            for (var id = 1; id <= 12; id++)
              CastTrack(
                id: id,
                kind: CastTrackKind.subtitles,
                name: 'Track $id',
              ),
          ],
          activeTrackIds: const [],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CastingView(cast: cast, title: 'Film', onClose: () {}),
        ),
      );
      await tester.tap(find.text('Subtitles'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        Focus.of(tester.element(find.text('Track 12'))).hasPrimaryFocus,
        isTrue,
      );
      expect(find.text('Track 12').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Track 12'));
      await tester.pumpAndSettle();
      expect(backend.tv.calls.last, 'tracks [12]');
      cast.dispose();
    },
  );

  test('cast labels tell renditions apart, like the phone', () {
    String label(String? language, String? name) => castTrackLabel(
      CastTrack(
        id: 1,
        kind: CastTrackKind.audio,
        language: language,
        name: name,
      ),
    );
    expect(label('ar', 'Arabic stereo'), 'Arabic');
    expect(label('ar', 'Arabic 5.1 5.1'), 'Arabic (5.1)');
    expect(label('fr', 'French AD'), 'French (AD)');
    expect(label(null, 'Commentary'), 'Commentary');
  });

  test('cast audio labels prefer receiver metadata and fall back to names', () {
    String label({
      String name = 'French',
      List<String>? roles,
      Object? info,
      String type = 'AUDIO',
    }) {
      final track = nvp.castMediaTracks({
        'tracks': [
          {
            'trackId': 42,
            'type': type,
            'language': 'fr',
            'name': name,
            'roles': ?roles,
            'audioTrackInfo': ?info,
          },
        ],
      })!.single;
      return castTrackLabel(CastTrack.fromReceiver(track)!);
    }

    expect(
      label(roles: ['description'], info: {'numAudioChannels': 8}),
      'French (7.1, AD)',
    );
    expect(label(name: 'French 5.1', info: {'numAudioChannels': 2}), 'French');
    expect(label(roles: ['alternate']), 'French');
    expect(label(name: 'French AD', roles: ['alternate']), 'French (AD)');
    expect(label(name: 'French 5.1', info: 'unknown'), 'French (5.1)');
    expect(label(name: 'French 2.1'), 'French');
    expect(
      label(type: 'TEXT', name: 'French AD', roles: ['description']),
      'French',
    );
  });

  test('the phone language matches a differently tagged TV track', () async {
    final backend = _FakeBackend();
    final cast = EYZFlowCastController(backend: backend);
    await cast.cast(_tv, _media, appId: 'A', subtitleLanguage: 'de');
    backend.tv.report(
      CastPlayback(
        state: CastPlayerState.playing,
        position: _min(1),
        tracks: const [
          CastTrack(id: 1, kind: CastTrackKind.audio, language: 'ar'),
          CastTrack(id: 5, kind: CastTrackKind.subtitles, language: 'deu'),
        ],
        activeTrackIds: const [1],
      ),
    );
    expect(backend.tv.calls.last, 'tracks [1, 5]');
    cast.dispose();
  });

  group('castMediaFor', () {
    const source = EYZFlowSource(
      id: 'stream-1',
      title: 'Film',
      sourceType: EYZFlowFilm('cat'),
    );

    test('a film carries the licence URL and the access token', () {
      final media = castMediaFor(
        source,
        startAt: _min(5),
        accessHeader: 'token',
      );
      expect(
        media.contentUrl,
        'https://stream.eyzflow.com/stream-1/manifest.mpd',
      );
      expect(media.contentType, 'application/dash+xml');
      expect(media.startAt, _min(5));
      expect(media.customData, {
        'manifestUrl': 'https://stream.eyzflow.com/stream-1/manifest.mpd',
        'licenseUrl':
            'https://api.eyzflow.com/v1/drm/stream-1/widevine/acquire',
        'accessToken': 'token',
      });
    });

    test('a clear stream carries no licence', () {
      final media = castMediaFor(source, startAt: Duration.zero);
      expect(media.customData, {
        'manifestUrl': 'https://stream.eyzflow.com/stream-1/manifest.mpd',
      });
    });
  });

  group('EYZFlowPlayer casting', () {
    setUpAll(() => setEYZFlowPlayerLanguage('en'));

    Future<_FakeBackend> pump(
      WidgetTester tester, {
      String? receiver = 'ABCD1234',
      bool isTv = false,
      List<PlaybackEvent>? events,
      _PhonePlayer Function()? phone,
    }) async {
      final backend = _FakeBackend();
      final client = MockClient((request) async {
        if (request.method == 'DELETE') return http.Response('', 204);
        if (request.url.path.endsWith('/heartbeat')) {
          return http.Response(jsonEncode({'status': 'active'}), 200);
        }
        return http.Response(jsonEncode({'id': 'ps_1'}), 201);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: EYZFlowPlayer(
            streamId: 'stream-1',
            title: 'Film',
            sourceType: const EYZFlowFilm('cat'),
            drmAuthorization: 'Bearer viewer',
            storefrontId: 'sf',
            isTv: isTv,
            httpClient: client,
            deviceIdStore: MemoryDeviceIdStore('device-1'),
            castReceiverAppId: receiver,
            castBackend: backend,
            debugOperatingSystemOverride: 'android',
            onPlaybackEvent: events?.add,
            playerBuilder: (_, target) => phone == null
                ? const SizedBox(key: Key('player'))
                : SystemVideoPlayer(
                    target: target,
                    createController: (_) async => phone(),
                  ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return backend;
    }

    VideoplayerFeatureView view(WidgetTester tester) => tester
        .widget<VideoplayerFeatureView>(find.byType(VideoplayerFeatureView));

    Future<void> pickTv(WidgetTester tester) async {
      view(tester).onCastRequested!(_min(10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (final subtitles in [true, false]) {
      testWidgets(
        'casts current phone tracks without a pick (subtitles $subtitles)',
        (tester) async {
          final phone = _PhonePlayer()
            ..selectedTextTrackId = subtitles ? 7 : null;
          final backend = await pump(tester, phone: () => phone);
          await pickTv(tester);
          backend.tv.report(_receiverTracks(active: [1, 3]));
          expect(
            backend.tv.calls.last,
            subtitles ? 'tracks [2, 4]' : 'tracks [2]',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    for (final subtitles in [true, false]) {
      testWidgets(
        'resumes the receiver tracks on the phone (subtitles $subtitles)',
        (tester) async {
          final resumed = _PhonePlayer();
          var players = 0;
          final backend = await pump(
            tester,
            phone: () => ++players == 1 ? _PhonePlayer() : resumed,
          );
          await pickTv(tester);
          backend.tv.report(_receiverTracks(active: [2, 4]));
          backend.tv.report(_receiverTracks(active: subtitles ? [1, 3] : [1]));
          await tester.pump();
          await tester.tap(find.text('Stop casting'));
          await tester.pump();
          await tester.pump();
          expect(players, 2);
          expect(resumed.selectedAudioTrackId, 6);
          expect(resumed.selectedTextTrackId, subtitles ? 8 : null);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets('unknown receiver selection preserves the outgoing subtitles', (
      tester,
    ) async {
      final resumed = _PhonePlayer()..selectedTextTrackId = null;
      var players = 0;
      final backend = await pump(
        tester,
        phone: () => ++players == 1 ? _PhonePlayer() : resumed,
      );
      await pickTv(tester);
      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.paused,
          tracks: _receiverTracks(active: []).tracks,
        ),
      );
      backend.tv.disconnect();
      await tester.pump();
      await tester.pump();
      expect(resumed.selectedTextTrackId, 7);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'disconnect closes an open casting panel and resumes the phone',
      (tester) async {
        final backend = await pump(tester);
        await pickTv(tester);
        backend.tv.report(_receiverTracks(active: [2, 4]));
        await tester.pump();
        await tester.tap(find.text('Audio'));
        await tester.pumpAndSettle();
        expect(find.text('English'), findsOneWidget);
        backend.tv.disconnect();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final player = tester.element(find.byKey(const Key('player')));
        expect(ModalRoute.isCurrentOf(player), isTrue);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('offers Cast once a TV is found', (tester) async {
      final backend = await pump(tester);
      expect(backend.scans, 1);
      expect(view(tester).castAvailable, isTrue);
    });

    testWidgets('a film without a receiver id casts to the EYZFlow receiver', (
      tester,
    ) async {
      final backend = await pump(tester, receiver: null);
      expect(view(tester).castAvailable, isTrue);

      view(tester).onCastRequested!(_min(10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();
      expect(backend.appId, 'A534F914');
      expect(backend.tv.loaded!.customData!['accessToken'], isA<String>());
    });

    testWidgets('a TV app offers no Cast', (tester) async {
      final backend = await pump(tester, isTv: true);
      expect(backend.scans, 0);
    });

    testWidgets('casting hands the film to the TV and back', (tester) async {
      final events = <PlaybackEvent>[];
      final backend = await pump(tester, events: events);

      view(tester).onCastRequested!(_min(10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();

      // The TV loads the film from the phone's position, with its DRM.
      final loaded = backend.tv.loaded!;
      expect(backend.appId, 'ABCD1234');
      expect(loaded.startAt, _min(10));
      final token = loaded.customData!['accessToken']! as String;
      final payload = jsonDecode(utf8.decode(base64Decode(token))) as Map;
      expect((payload['parameters'] as Map)['playback_session_id'], 'ps_1');
      expect(find.byKey(const Key('player')), findsNothing);
      expect(find.text('Connecting to Living Room TV…'), findsOneWidget);

      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(10),
          duration: _min(90),
        ),
      );
      await tester.pump();
      expect(find.text('Playing on Living Room TV'), findsOneWidget);
      expect(events.whereType<PlaybackResumed>(), isNotEmpty);

      backend.tv.report(
        CastPlayback(
          state: CastPlayerState.playing,
          position: _min(25),
          duration: _min(90),
        ),
      );
      await tester.tap(find.text('Stop casting'));
      await tester.pumpAndSettle();

      // The phone plays again, from where the TV was.
      expect(find.byKey(const Key('player')), findsOneWidget);
      expect(_progress(view(tester)), 25 * 60);
      expect(backend.tv.calls.last, 'stop');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused cast shows why and the phone plays on', (
      tester,
    ) async {
      final backend = await pump(tester);
      view(tester).onCastRequested!(_min(3));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Living Room TV'));
      await tester.pump();

      backend.tv.refuse('LOAD_FAILED');
      await tester.pumpAndSettle();

      expect(find.text('Could not play on Living Room TV.'), findsOneWidget);
      expect(find.byKey(const Key('player')), findsOneWidget);
      expect(_progress(view(tester)), 3 * 60);

      await tester.pumpWidget(const SizedBox());
    });
  });
}

CastPlayback _receiverTracks({required List<int> active}) => CastPlayback(
  state: CastPlayerState.paused,
  tracks: const [
    CastTrack(id: 1, kind: CastTrackKind.audio, language: 'fr'),
    CastTrack(id: 2, kind: CastTrackKind.audio, language: 'en'),
    CastTrack(id: 3, kind: CastTrackKind.subtitles, language: 'fr'),
    CastTrack(id: 4, kind: CastTrackKind.subtitles, language: 'de'),
  ],
  activeTrackIds: active,
);

class _PhonePlayer implements VideoplaybackController, VideoplaybackTracks {
  @override
  final value = const VideoplaybackValue();
  @override
  int? selectedAudioTrackId = 5;
  @override
  int? selectedTextTrackId = 7;
  @override
  Future<List<PlayerAudioTrack>> audioTracks() async => const [
    PlayerAudioTrack(trackId: 5, language: 'eng'),
    PlayerAudioTrack(trackId: 6, language: 'fra'),
  ];
  @override
  Future<List<PlayerTextTrack>> textTracks() async => const [
    PlayerTextTrack(trackId: 7, language: 'deu'),
    PlayerTextTrack(trackId: 8, language: 'fr_FR'),
  ];
  @override
  Future<bool> selectAudioTrack(int id) async {
    selectedAudioTrackId = id;
    return true;
  }

  @override
  Future<bool> selectTextTrack(int? id) async {
    selectedTextTrackId = id;
    return true;
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  void addListener(void Function(VideoplaybackValue) listener) {}
  @override
  void removeListener(void Function(VideoplaybackValue) listener) {}
  @override
  Future<void> dispose() async {}
}

double? _progress(VideoplayerFeatureView view) => switch (view.target) {
  VideoplayerSourceTarget(:final source) => source.progressSeconds,
  VideoplayerTrailerTarget(:final source) => source.progressSeconds,
};

final class _ThrowingBackend implements CastBackend {
  @override
  Future<List<CastTarget>> discover({Duration? timeout}) =>
      Future.error(Exception('no wifi'));

  @override
  Future<CastConnection> connect(CastTarget target, {required String appId}) =>
      Future.error(UnimplementedError());
}
