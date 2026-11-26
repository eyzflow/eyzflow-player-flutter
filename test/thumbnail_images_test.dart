import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:eyzflow_player/src/player/thumbnail_images.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uri _base = Uri.parse(
  'https://stream.eyzflow.com/s1/thumbnails/thumbnail.vtt',
);

String _time(int seconds) =>
    '00:${(seconds ~/ 60).toString().padLeft(2, '0')}:'
    '${(seconds % 60).toString().padLeft(2, '0')}.000';

/// [count] tiles of 199×112, two per sprite, stacked one above the other.
ThumbnailTrack _track(int count) => ThumbnailTrack.parse(
  <String>[
    'WEBVTT',
    for (int i = 0; i < count; i++)
      '\n${_time(i * 5)} --> ${_time(i * 5 + 5)}\n'
          'thumb_${i ~/ 2}.png#xywh=0,${(i % 2) * 112},199,112',
  ].join('\n'),
  _base,
);

/// A 199×224 sprite: a red tile on top of a blue one.
Future<Uint8List> _sprite() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 199, 112),
    Paint()..color = const Color(0xFFFF0000),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 112, 199, 112),
    Paint()..color = const Color(0xFF0000FF),
  );
  final ui.Image image = await recorder.endRecording().toImage(199, 224);
  final ByteData png = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  return png.buffer.asUint8List();
}

/// Waits until [images] has [tile]'s frame ready.
Future<ui.Image> _frame(ThumbnailImages images, ThumbnailTile tile) async {
  final ui.Image? ready = images.imageFor(tile);
  if (ready != null) return ready;
  final Completer<ui.Image> done = Completer<ui.Image>();
  void listener() {
    final ui.Image? image = images.imageFor(tile);
    if (image != null && !done.isCompleted) done.complete(image);
  }

  images.addListener(listener);
  try {
    return await done.future.timeout(const Duration(seconds: 10));
  } finally {
    images.removeListener(listener);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preload fetches every sprite once, up front', () async {
    final List<Uri> requests = <Uri>[];
    final ThumbnailImages images = ThumbnailImages(
      _track(10),
      loader: ThumbnailLoader(
        client: MockClient((http.Request request) async {
          requests.add(request.url);
          return http.Response.bytes(<int>[1, 2, 3], 200);
        }),
      ),
    );
    addTearDown(images.dispose);

    await images.preload();
    await images.preload();

    expect(
      requests.map((Uri u) => u.pathSegments.last),
      unorderedEquals(<String>[
        for (int i = 0; i < 5; i++) 'thumb_$i.png',
      ]),
    );
    for (final Uri url in images.images) {
      expect(images.isLoaded(url), isTrue);
    }

    // Asking for frames reads what was downloaded, never the network.
    for (final ThumbnailTile tile in images.track.tiles) {
      images.imageFor(tile);
    }
    expect(requests, hasLength(5));
  });

  test('a sprite that fails to load leaves its tiles without a frame', () async {
    final ThumbnailImages images = ThumbnailImages(
      _track(4),
      loader: ThumbnailLoader(
        client: MockClient((_) async => http.Response('', 404)),
      ),
    );
    addTearDown(images.dispose);

    await images.preload();

    expect(images.images.any(images.isLoaded), isFalse);
    expect(images.imageFor(images.track.tiles.first), isNull);
  });

  testWidgets('a tile is cut without the tile above it', (tester) async {
    await tester.runAsync(() async {
      final Uint8List sprite = await _sprite();
      final ThumbnailImages images = ThumbnailImages(
        _track(2),
        loader: ThumbnailLoader(
          client: MockClient((_) async => http.Response.bytes(sprite, 200)),
        ),
      );
      addTearDown(images.dispose);
      await images.preload();

      // The lower (blue) tile, directly under the red one.
      final ThumbnailTile lower = images.track.tiles[1];
      final ui.Image frame = await _frame(images, lower);
      expect(frame.width, 199);
      expect(frame.height, 112);

      final ByteData pixels = (await frame.toByteData())!;
      for (int y = 0; y < frame.height; y++) {
        for (int x = 0; x < frame.width; x++) {
          final int offset = (y * frame.width + x) * 4;
          expect(
            <int>[
              pixels.getUint8(offset),
              pixels.getUint8(offset + 1),
              pixels.getUint8(offset + 2),
            ],
            <int>[0, 0, 255],
            reason: 'pixel $x,$y',
          );
        }
      }
    });
  });

  testWidgets(
    'no tile shows a neighbour on any side, cut or scaled for the screen',
    (tester) async {
      await tester.runAsync(() async {
        final Uint8List sprite = await _gridSprite();
        final ThumbnailImages images = ThumbnailImages(
          _gridTrack(),
          loader: ThumbnailLoader(
            client: MockClient((_) async => http.Response.bytes(sprite, 200)),
          ),
          maxDecoded: 1,
        );
        addTearDown(images.dispose);
        await images.preload();

        // Corners, edges and the middle tile: each touches neighbours on a
        // different set of sides (left, right, above, below).
        for (final ThumbnailTile tile in images.track.tiles) {
          final int column = tile.x! ~/ _tileWidth;
          final int row = tile.y! ~/ _tileHeight;
          final List<int> colour = _gridColour(column, row);
          final ui.Image frame = await _frame(images, tile);
          expect(<int>[frame.width, frame.height], <int>[
            _tileWidth,
            _tileHeight,
          ]);
          await _expectOnly(frame, colour, '$column,$row cut');

          // The preview is 192 wide and drawn at the screen's pixel ratio,
          // so the tile is scaled down on a phone and up on a TV.
          for (final Size size in const <Size>[
            Size(192, 108),
            Size(576, 324),
          ]) {
            for (final FilterQuality quality in const <FilterQuality>[
              FilterQuality.low,
              FilterQuality.medium,
            ]) {
              final ui.Image scaled = await _scale(frame, size, quality);
              await _expectOnly(
                scaled,
                colour,
                '$column,$row at ${size.width.toInt()} ($quality)',
              );
              scaled.dispose();
            }
          }
        }
      });
    },
  );
}

const int _tileWidth = 199;
const int _tileHeight = 112;

/// A distinct colour per tile of the 3×3 grid.
List<int> _gridColour(int column, int row) => <int>[
  20 + column * 110,
  20 + row * 110,
  128,
];

/// A 3×3 sprite of 199×112 tiles packed edge to edge, as the packager cuts
/// them, each a different colour.
Future<Uint8List> _gridSprite() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  for (int row = 0; row < 3; row++) {
    for (int column = 0; column < 3; column++) {
      final List<int> c = _gridColour(column, row);
      canvas.drawRect(
        Rect.fromLTWH(
          column * _tileWidth.toDouble(),
          row * _tileHeight.toDouble(),
          _tileWidth.toDouble(),
          _tileHeight.toDouble(),
        ),
        Paint()..color = Color.fromARGB(255, c[0], c[1], c[2]),
      );
    }
  }
  final ui.Image image = await recorder.endRecording().toImage(
    _tileWidth * 3,
    _tileHeight * 3,
  );
  final ByteData png = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!;
  image.dispose();
  return png.buffer.asUint8List();
}

ThumbnailTrack _gridTrack() => ThumbnailTrack.parse(
  <String>[
    'WEBVTT',
    for (int i = 0; i < 9; i++)
      '\n${_time(i * 5)} --> ${_time(i * 5 + 5)}\n'
          'grid.png#xywh=${(i % 3) * _tileWidth},${(i ~/ 3) * _tileHeight},'
          '$_tileWidth,$_tileHeight',
  ].join('\n'),
  _base,
);

/// [image] drawn into [size] as `RawImage` with `BoxFit.fill` draws it.
Future<ui.Image> _scale(
  ui.Image image,
  Size size,
  FilterQuality quality,
) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint()..filterQuality = quality,
  );
  return recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
}

/// Every pixel of [image] is [colour], give or take rounding.
Future<void> _expectOnly(ui.Image image, List<int> colour, String what) async {
  final ByteData pixels = (await image.toByteData())!;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int offset = (y * image.width + x) * 4;
      for (int channel = 0; channel < 3; channel++) {
        final int value = pixels.getUint8(offset + channel);
        if ((value - colour[channel]).abs() > 2) {
          fail(
            '$what: pixel $x,$y is '
            '${<int>[for (int c = 0; c < 3; c++) pixels.getUint8(offset + c)]}'
            ', expected $colour',
          );
        }
      }
    }
  }
}
