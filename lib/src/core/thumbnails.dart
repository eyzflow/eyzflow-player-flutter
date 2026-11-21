import 'package:http/http.dart' as http;

/// One preview image: a whole image, or a tile cut from a sprite with
/// `#xywh=x,y,w,h`, shown for [start] up to [end].
final class ThumbnailTile {
  const ThumbnailTile({
    required this.start,
    required this.end,
    required this.image,
    this.x,
    this.y,
    this.width,
    this.height,
  });

  final Duration start;
  final Duration end;

  /// The image URL, resolved against the track's URL.
  final Uri image;

  /// The tile inside [image], in image pixels; all null for a whole image.
  final int? x;
  final int? y;
  final int? width;
  final int? height;

  bool get isSprite => width != null && height != null;

  @override
  String toString() =>
      'ThumbnailTile($start–$end ${image.pathSegments.last}'
      '${isSprite ? '#$x,$y,$width,$height' : ''})';
}

/// A WebVTT thumbnail track, as EYZFlow packages one for every stream
/// (`thumbnails/thumbnail.vtt`: a 199×112 tile per 5 seconds, cut from
/// sprite images).
final class ThumbnailTrack {
  ThumbnailTrack(List<ThumbnailTile> tiles)
    : tiles = List<ThumbnailTile>.unmodifiable(
        <ThumbnailTile>[...tiles]..sort(
          (ThumbnailTile a, ThumbnailTile b) => a.start.compareTo(b.start),
        ),
      );

  final List<ThumbnailTile> tiles;

  bool get isEmpty => tiles.isEmpty;

  /// The tile shown at [position]: the last one starting at or before it.
  /// Past the end the last tile, before the start the first.
  ThumbnailTile? at(Duration position) {
    if (tiles.isEmpty) return null;
    var low = 0;
    var high = tiles.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (tiles[mid].start <= position) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return tiles[low];
  }

  /// Parses a WebVTT thumbnail track. Image URLs are resolved against
  /// [base], the track's own URL. Cues it cannot read are skipped.
  static ThumbnailTrack parse(String vtt, Uri base) {
    final lines = vtt
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final tiles = <ThumbnailTile>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final arrow = line.indexOf('-->');
      if (arrow < 0) continue;
      final start = _time(line.substring(0, arrow));
      final end = _time(
        line.substring(arrow + 3).trim().split(RegExp(r'\s+')).first,
      );
      if (start == null || end == null) continue;
      // The payload is the next non-empty line.
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isEmpty) {
        j++;
      }
      if (j >= lines.length) break;
      final tile = _tile(lines[j].trim(), base, start, end);
      if (tile != null) tiles.add(tile);
      i = j;
    }
    return ThumbnailTrack(tiles);
  }

  static ThumbnailTile? _tile(
    String payload,
    Uri base,
    Duration start,
    Duration end,
  ) {
    if (payload.isEmpty || payload.contains('-->')) return null;
    final hash = payload.indexOf('#xywh=');
    final path = hash < 0 ? payload : payload.substring(0, hash);
    final Uri image;
    try {
      image = base.resolve(path);
    } on FormatException {
      return null;
    }
    if (hash < 0) return ThumbnailTile(start: start, end: end, image: image);
    final parts = payload
        .substring(hash + 6)
        .split(',')
        .map((p) => int.tryParse(p.trim()))
        .toList();
    if (parts.length != 4 || parts.any((p) => p == null || p < 0)) {
      return ThumbnailTile(start: start, end: end, image: image);
    }
    return ThumbnailTile(
      start: start,
      end: end,
      image: image,
      x: parts[0],
      y: parts[1],
      width: parts[2],
      height: parts[3],
    );
  }

  /// `hh:mm:ss.mmm` or `mm:ss.mmm`.
  static Duration? _time(String value) {
    final parts = value.trim().split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final seconds = double.tryParse(parts.last);
    final minutes = int.tryParse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.tryParse(parts.first) : 0;
    if (seconds == null || minutes == null || hours == null) return null;
    return Duration(
      milliseconds: ((hours * 3600 + minutes * 60) * 1000 + seconds * 1000)
          .round(),
    );
  }
}

/// Loads thumbnail tracks, once per URL. A track that cannot be loaded or
/// parsed loads as null: the player seeks without previews.
final class ThumbnailLoader {
  ThumbnailLoader({this._client});

  final http.Client? _client;
  final _cache = <Uri, Future<ThumbnailTrack?>>{};

  /// The one the players use.
  static final ThumbnailLoader shared = ThumbnailLoader();

  Future<ThumbnailTrack?> load(Uri url) =>
      _cache[url] ??= _fetch(url).then((track) {
        // A failure is not remembered: the next film (or the next try) loads
        // again.
        if (track == null) _cache.remove(url);
        return track;
      });

  Future<ThumbnailTrack?> _fetch(Uri url) async {
    try {
      final client = _client;
      final response = client == null
          ? await http.get(url)
          : await client.get(url);
      if (response.statusCode != 200) return null;
      final track = ThumbnailTrack.parse(response.body, url);
      return track.isEmpty ? null : track;
    } on Object {
      return null;
    }
  }
}
