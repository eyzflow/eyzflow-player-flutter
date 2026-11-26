import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/thumbnails.dart';

/// The images of one film's thumbnail track, downloaded all at once when
/// the track loads and kept for as long as the film plays, so seeking never
/// waits on the network or on Flutter's shared image cache.
///
/// The downloaded bytes are kept compressed. Only a few sprites are decoded
/// at a time, and each tile is copied out of its sprite pixel for pixel, so
/// a preview never shows the edge of the tile next to it. Listeners are
/// told when an image becomes ready.
final class ThumbnailImages extends ChangeNotifier {
  ThumbnailImages(
    this.track, {
    required this._loader,
    this.maxDecoded = 3,
    this.maxTiles = 32,
    this.concurrency = 4,
  });

  final ThumbnailTrack track;
  final ThumbnailLoader _loader;

  /// How many sprites are kept decoded.
  final int maxDecoded;

  /// How many cut tiles are kept.
  final int maxTiles;

  /// How many images download at once.
  final int concurrency;

  final Map<Uri, Uint8List> _bytes = <Uri, Uint8List>{};

  // Insertion order is the use order: the first entry is the least recent.
  final LinkedHashMap<Uri, ui.Image> _decoded = LinkedHashMap<Uri, ui.Image>();
  final LinkedHashMap<ThumbnailTile, ui.Image> _tiles =
      LinkedHashMap<ThumbnailTile, ui.Image>();
  final Set<Uri> _decoding = <Uri>{};

  bool _preloading = false;
  bool _disposed = false;

  /// The track's distinct images, in the order their tiles play.
  List<Uri> get images =>
      <Uri>{for (final ThumbnailTile tile in track.tiles) tile.image}.toList();

  /// Whether [url] has been downloaded.
  bool isLoaded(Uri url) => _bytes.containsKey(url);

  /// Downloads every image of the track, [concurrency] at a time. Calling it
  /// again does nothing.
  Future<void> preload() async {
    if (_preloading) return;
    _preloading = true;
    final Iterator<Uri> pending = images.iterator;
    Future<void> worker() async {
      while (!_disposed && pending.moveNext()) {
        final Uri url = pending.current;
        final Uint8List? bytes = await _loader.loadImage(url);
        if (_disposed) return;
        if (bytes == null) continue;
        _bytes[url] = bytes;
        notifyListeners();
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);
  }

  /// The picture for [tile], cut from its sprite, or null while its image is
  /// still downloading or decoding (listeners hear when it is ready) or when
  /// it cannot be loaded.
  ///
  /// The image belongs to this cache and may be disposed when it is evicted:
  /// a widget that keeps it must hold its own [ui.Image.clone].
  ui.Image? imageFor(ThumbnailTile tile) {
    if (_disposed) return null;
    final ui.Image? cut = _tiles.remove(tile);
    if (cut != null) return _tiles[tile] = cut;
    final ui.Image? sprite = _decoded.remove(tile.image);
    if (sprite == null) {
      _decode(tile.image);
      return null;
    }
    _decoded[tile.image] = sprite;
    if (!tile.isSprite) return sprite;
    final ui.Image? image = _cut(sprite, tile);
    if (image == null) return null;
    _tiles[tile] = image;
    while (_tiles.length > maxTiles) {
      _tiles.remove(_tiles.keys.first)!.dispose();
    }
    return image;
  }

  void _decode(Uri url) {
    final Uint8List? bytes = _bytes[url];
    if (bytes == null || _decoding.contains(url)) return;
    _decoding.add(url);
    unawaited(() async {
      ui.Image? image;
      try {
        final ui.Codec codec = await ui.instantiateImageCodec(bytes);
        try {
          image = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } on Object {
        image = null;
      }
      _decoding.remove(url);
      if (_disposed) {
        image?.dispose();
        return;
      }
      if (image == null) {
        // Undecodable: drop the bytes so it is not tried on every seek.
        _bytes.remove(url);
        return;
      }
      _decoded[url] = image;
      while (_decoded.length > maxDecoded) {
        _decoded.remove(_decoded.keys.first)!.dispose();
      }
      notifyListeners();
    }());
  }

  /// [tile]'s pixels copied 1:1 out of [sprite] with no filtering, so
  /// scaling the result later cannot sample a neighbouring tile.
  static ui.Image? _cut(ui.Image sprite, ThumbnailTile tile) {
    final int left = tile.x!.clamp(0, sprite.width);
    final int top = tile.y!.clamp(0, sprite.height);
    final int width = tile.width!.clamp(0, sprite.width - left);
    final int height = tile.height!.clamp(0, sprite.height - top);
    if (width == 0 || height == 0) return null;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      sprite,
      Rect.fromLTWH(
        left.toDouble(),
        top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.none,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      return picture.toImageSync(width, height);
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final ui.Image image in _tiles.values) {
      image.dispose();
    }
    for (final ui.Image image in _decoded.values) {
      image.dispose();
    }
    _tiles.clear();
    _decoded.clear();
    _bytes.clear();
    super.dispose();
  }
}
