import 'package:eyzflow_player/src/native/native_video_player.dart';
import 'package:eyzflow_player/src/player/player_policy.dart';
import 'package:eyzflow_player/src/player/system_player_tracks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('systemAudioTracks', () {
    test('maps plugin index to trackId and keeps the language', () {
      final List<PlayerAudioTrack> mapped =
          systemAudioTracks(const <NativeVideoPlayerAudioTrack>[
            NativeVideoPlayerAudioTrack(
              index: 0,
              language: 'de',
              displayName: 'Deutsch',
            ),
            NativeVideoPlayerAudioTrack(
              index: 1,
              language: 'en',
              displayName: 'English',
            ),
          ]);
      expect(mapped.map((PlayerAudioTrack t) => t.trackId), <int>[0, 1]);
      expect(mapped.map((PlayerAudioTrack t) => t.language), <String>[
        'de',
        'en',
      ]);
      // The plugin does not report a channel count.
      expect(mapped.every((PlayerAudioTrack t) => t.channel == null), isTrue);
    });

    test('reads the initially selected id from the isSelected flag', () {
      expect(
        systemSelectedIndex(
          const <NativeVideoPlayerAudioTrack>[
            NativeVideoPlayerAudioTrack(
              index: 0,
              language: 'de',
              displayName: 'Deutsch',
            ),
            NativeVideoPlayerAudioTrack(
              index: 1,
              language: 'en',
              displayName: 'English',
              isSelected: true,
            ),
          ],
          (NativeVideoPlayerAudioTrack t) => t.isSelected,
          (NativeVideoPlayerAudioTrack t) => t.index,
        ),
        1,
      );
    });

    test('reports no selection when nothing is flagged', () {
      expect(
        systemSelectedIndex(
          const <NativeVideoPlayerAudioTrack>[
            NativeVideoPlayerAudioTrack(
              index: 0,
              language: 'de',
              displayName: 'Deutsch',
            ),
          ],
          (NativeVideoPlayerAudioTrack t) => t.isSelected,
          (NativeVideoPlayerAudioTrack t) => t.index,
        ),
        isNull,
      );
    });
  });

  group('systemTextTracks', () {
    test('maps plugin index to trackId and keeps the language', () {
      final List<PlayerTextTrack> mapped =
          systemTextTracks(const <NativeVideoPlayerSubtitleTrack>[
            NativeVideoPlayerSubtitleTrack(
              index: 0,
              language: 'de',
              displayName: 'Deutsch',
            ),
          ]);
      expect(mapped.single.trackId, 0);
      expect(mapped.single.language, 'de');
    });
  });
}
