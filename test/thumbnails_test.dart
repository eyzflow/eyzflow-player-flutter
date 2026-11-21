import 'package:eyzflow_player/src/core/thumbnails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _base = Uri.parse(
  'https://stream.eyzflow.com/s1/thumbnails/thumbnail.vtt',
);

/// The start of a real EYZFlow track.
const _vtt = '''WEBVTT

00:00:00.000 --> 00:00:05.000
thumb_0001.jpg#xywh=0,0,199,112

00:00:05.000 --> 00:00:10.000
thumb_0001.jpg#xywh=199,0,199,112

00:00:10.000 --> 00:00:15.000
thumb_0002.jpg#xywh=0,112,199,112
''';

void main() {
  group('ThumbnailTrack.parse', () {
    test('reads sprite tiles and resolves their images', () {
      final track = ThumbnailTrack.parse(_vtt, _base);
      expect(track.tiles, hasLength(3));
      final second = track.tiles[1];
      expect(second.start, const Duration(seconds: 5));
      expect(second.end, const Duration(seconds: 10));
      expect(
        second.image.toString(),
        'https://stream.eyzflow.com/s1/thumbnails/thumb_0001.jpg',
      );
      expect(
        (second.x, second.y, second.width, second.height),
        (199, 0, 199, 112),
      );
      expect(second.isSprite, isTrue);
    });

    test('reads whole images, short times, cue ids and CRLF', () {
      final track = ThumbnailTrack.parse(
        'WEBVTT\r\n\r\n1\r\n00:05.500 --> 00:10.000 align:start\r\n'
        'https://cdn.example/a.jpg\r\n',
        _base,
      );
      final tile = track.tiles.single;
      expect(tile.start, const Duration(milliseconds: 5500));
      expect(tile.image.toString(), 'https://cdn.example/a.jpg');
      expect(tile.isSprite, isFalse);
    });

    test('skips cues it cannot read', () {
      final track = ThumbnailTrack.parse(
        'WEBVTT\n\nnot a time --> 00:00:05.000\na.jpg\n\n'
        '00:00:05.000 --> 00:00:10.000\nb.jpg#xywh=1,2\n',
        _base,
      );
      // The broken xywh still shows the whole image.
      expect(track.tiles.single.image.pathSegments.last, 'b.jpg');
      expect(track.tiles.single.isSprite, isFalse);
    });
  });

  group('ThumbnailTrack.at', () {
    final track = ThumbnailTrack.parse(_vtt, _base);

    test('finds the tile showing at a time', () {
      expect(track.at(Duration.zero)!.x, 0);
      expect(track.at(const Duration(seconds: 7))!.x, 199);
      expect(track.at(const Duration(seconds: 10))!.y, 112);
    });

    test('holds the last tile past the end, the first before the start', () {
      expect(track.at(const Duration(hours: 2)), same(track.tiles.last));
      expect(track.at(const Duration(seconds: -1)), same(track.tiles.first));
    });

    test('an empty track has no tile', () {
      expect(ThumbnailTrack(const []).at(Duration.zero), isNull);
    });
  });

  group('ThumbnailLoader', () {
    test('loads once per URL', () async {
      var requests = 0;
      final loader = ThumbnailLoader(
        client: MockClient((_) async {
          requests += 1;
          return http.Response(_vtt, 200);
        }),
      );
      final a = await loader.load(_base);
      final b = await loader.load(_base);
      expect(a!.tiles, hasLength(3));
      expect(b, same(a));
      expect(requests, 1);
    });

    test('a missing or empty track loads as null and is tried again', () async {
      var requests = 0;
      final loader = ThumbnailLoader(
        client: MockClient((_) async {
          requests += 1;
          return requests == 1
              ? http.Response('not found', 404)
              : http.Response('WEBVTT\n', 200);
        }),
      );
      expect(await loader.load(_base), isNull);
      expect(await loader.load(_base), isNull);
      expect(requests, 2);
    });

    test('a network failure loads as null', () async {
      final loader = ThumbnailLoader(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      expect(await loader.load(_base), isNull);
    });
  });
}
