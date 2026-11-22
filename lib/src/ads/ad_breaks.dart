import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// The ad breaks marked on a stream in the dashboard (Stream → Signals → Ad
/// break). The backend writes each one into the plain manifests as SCTE-35:
///
/// * HLS: an `#EXT-X-DATERANGE` with `SCTE35-OUT` in every media playlist,
///   anchored by `#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z` before
///   the first segment, so `START-DATE` minus the anchor is the position in
///   the content.
/// * DASH: an `<EventStream schemeIdUri="urn:scte:scte35:2014:xml+bin">` in
///   the first Period, with `presentationTime` in its `timescale`.
///
/// Intro and credits signals (`CLASS="com.eyzflow.signal"`,
/// `urn:eyzflow:signal`) are written next to them and are not ad breaks.
///
/// The same rules as the web player's `ad-breaks.ts`.
@immutable
final class AdBreak {
  const AdBreak({required this.id, required this.start, this.duration});

  final String id;

  /// Position in the content.
  final Duration start;

  /// The planned length of the ad pod, when the break has one. Not sent to
  /// the ad server: the tag decides the pod.
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is AdBreak &&
      other.id == id &&
      other.start == start &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(id, start, duration);

  @override
  String toString() => 'AdBreak($id at $start)';
}

/// The SCTE-35 schemes a DASH EventStream can carry. EYZFlow writes the first.
const Set<String> scte35Schemes = <String>{
  'urn:scte:scte35:2014:xml+bin',
  'urn:scte:scte35:2013:xml',
  'urn:scte:scte35:2014:bin',
};

/// The class EYZFlow gives its intro and credits DATERANGEs.
const String _hlsSpanClass = 'com.eyzflow.signal';

/// A break at or before this is a pre-roll: it plays before the content
/// starts.
const Duration prerollWindow = Duration(milliseconds: 500);

/// Playback moving further than this between two position reports is a seek
/// or a jump, not playing through: breaks passed that way are not played.
/// The native player reports the position every 0.5 s while playing.
const Duration maxPlayStep = Duration(seconds: 2);

final RegExp _hlsAttribute = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

Map<String, String> _hlsAttributes(String list) => <String, String>{
  for (final RegExpMatch m in _hlsAttribute.allMatches(list))
    m.group(1)!: _unquote(m.group(2)!),
};

String _unquote(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.substring(1, value.length - 1)
    : value;

/// The ad breaks in one HLS playlist (a media playlist; a master playlist
/// carries none, but is read the same way).
///
/// A DATERANGE is an ad break when it has `SCTE35-OUT` (or `SCTE35-CMD`) and
/// is not one of EYZFlow's span signals. Its position is its `START-DATE`
/// minus the first `EXT-X-PROGRAM-DATE-TIME`, which sits before the first
/// segment. Without that anchor a DATERANGE cannot be placed and is skipped.
List<AdBreak> parseHlsAdBreaks(String playlist) {
  DateTime? anchor;
  final List<AdBreak> breaks = <AdBreak>[];
  final Set<String> seen = <String>{};
  final List<Map<String, String>> ranges = <Map<String, String>>[];
  for (final String raw in playlist.split('\n')) {
    final String line = raw.trim();
    if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
      anchor ??= DateTime.tryParse(line.substring(25).trim());
    } else if (line.startsWith('#EXT-X-DATERANGE:')) {
      ranges.add(_hlsAttributes(line.substring(17)));
    }
  }
  if (anchor == null) return breaks;
  for (final Map<String, String> range in ranges) {
    if (range['CLASS'] == _hlsSpanClass) continue;
    if (!range.containsKey('SCTE35-OUT') && !range.containsKey('SCTE35-CMD')) {
      continue;
    }
    final DateTime? startDate = DateTime.tryParse(range['START-DATE'] ?? '');
    if (startDate == null) continue;
    final Duration start = startDate.difference(anchor);
    if (start.isNegative) continue;
    final String id = range['ID'] ?? 't${start.inMilliseconds}';
    if (!seen.add(id)) continue;
    breaks.add(
      AdBreak(
        id: id,
        start: start,
        duration: _seconds(range['PLANNED-DURATION'] ?? range['DURATION']),
      ),
    );
  }
  breaks.sort((AdBreak a, AdBreak b) => a.start.compareTo(b.start));
  return breaks;
}

Duration? _seconds(String? value) {
  final double? s = value == null ? null : double.tryParse(value);
  if (s == null || s <= 0) return null;
  return Duration(microseconds: (s * Duration.microsecondsPerSecond).round());
}

/// The media playlists a master playlist points at (video variants first,
/// then audio renditions), resolved against [master]. The backend writes the
/// same markers into each, so the first one is enough.
List<Uri> hlsMediaPlaylistUris(String masterPlaylist, Uri master) {
  final List<String> lines = masterPlaylist.split('\n');
  final List<Uri> variants = <Uri>[];
  final List<Uri> audio = <Uri>[];
  for (var i = 0; i < lines.length; i++) {
    final String line = lines[i].trim();
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      for (var j = i + 1; j < lines.length; j++) {
        final String next = lines[j].trim();
        if (next.isEmpty) continue;
        if (!next.startsWith('#')) variants.add(master.resolve(next));
        break;
      }
    } else if (line.startsWith('#EXT-X-MEDIA:')) {
      final Map<String, String> attrs = _hlsAttributes(line.substring(13));
      final String? uri = attrs['URI'];
      if (attrs['TYPE'] == 'AUDIO' && uri != null) {
        audio.add(master.resolve(uri));
      }
    }
  }
  return <Uri>[...variants, ...audio];
}

final RegExp _eventStream = RegExp(
  r'<EventStream\b([^>]*?)(?:/>|>([\s\S]*?)</EventStream>)',
);
final RegExp _event = RegExp(r'<Event\b([^>]*?)(?:/>|>)');
final RegExp _xmlAttribute = RegExp(r'([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"');

Map<String, String> _xmlAttributes(String list) => <String, String>{
  for (final RegExpMatch m in _xmlAttribute.allMatches(list))
    m.group(1)!: m.group(2)!,
};

/// The ad breaks in an MPD: the events of its SCTE-35 EventStreams. Their
/// `presentationTime` is in the stream's `timescale` (1 when absent), less
/// its `presentationTimeOffset`.
List<AdBreak> parseDashAdBreaks(String mpd) {
  final List<AdBreak> breaks = <AdBreak>[];
  final Set<String> seen = <String>{};
  for (final RegExpMatch stream in _eventStream.allMatches(mpd)) {
    final Map<String, String> attrs = _xmlAttributes(stream.group(1)!);
    if (!scte35Schemes.contains(attrs['schemeIdUri'])) continue;
    final int timescale = int.tryParse(attrs['timescale'] ?? '') ?? 1;
    if (timescale <= 0) continue;
    final int offset = int.tryParse(attrs['presentationTimeOffset'] ?? '') ?? 0;
    for (final RegExpMatch event in _event.allMatches(stream.group(2) ?? '')) {
      final Map<String, String> e = _xmlAttributes(event.group(1)!);
      final int ticks = int.tryParse(e['presentationTime'] ?? '0') ?? 0;
      final int? length = int.tryParse(e['duration'] ?? '');
      final Duration start = Duration(
        microseconds: ((ticks - offset) * 1000000 / timescale).round(),
      );
      if (start.isNegative) continue;
      final String id = e['id'] ?? 't${start.inMilliseconds}';
      if (!seen.add(id)) continue;
      breaks.add(
        AdBreak(
          id: id,
          start: start,
          duration: length == null || length <= 0
              ? null
              : Duration(microseconds: (length * 1000000 / timescale).round()),
        ),
      );
    }
  }
  breaks.sort((AdBreak a, AdBreak b) => a.start.compareTo(b.start));
  return breaks;
}

/// Reads the ad breaks of the HLS stream at [master], the playlist the native
/// player loads: from the master itself and from its first media playlist.
/// A manifest that cannot be loaded gives no breaks; the caller then treats
/// the stream as one without markers.
Future<List<AdBreak>> loadHlsAdBreaks(
  http.Client client,
  Uri master, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final http.Response response = await client.get(master).timeout(timeout);
    if (response.statusCode != 200) return const <AdBreak>[];
    final String body = response.body;
    final List<AdBreak> own = parseHlsAdBreaks(body);
    if (own.isNotEmpty || !body.contains('#EXT-X-STREAM-INF')) return own;
    final List<Uri> media = hlsMediaPlaylistUris(body, master);
    if (media.isEmpty) return const <AdBreak>[];
    final http.Response playlist = await client
        .get(media.first)
        .timeout(timeout);
    if (playlist.statusCode != 200) return const <AdBreak>[];
    return parseHlsAdBreaks(playlist.body);
  } on Object {
    return const <AdBreak>[];
  }
}

/// The stream's ad breaks, each played at most once per impression.
final class AdBreakSchedule {
  AdBreakSchedule([Iterable<AdBreak> breaks = const <AdBreak>[]]) {
    addAll(breaks);
  }

  final Map<String, AdBreak> _breaks = <String, AdBreak>{};
  final Set<String> _played = <String>{};

  void addAll(Iterable<AdBreak> breaks) {
    for (final AdBreak adBreak in breaks) {
      _breaks[adBreak.id] = adBreak;
    }
  }

  /// The stream has ad breaks: ads play at them, not where the ad tag would
  /// put them.
  bool get hasBreaks => _breaks.isNotEmpty;

  List<AdBreak> get breaks => _ordered();

  /// The pre-roll break, if the stream has one not yet played; marked as
  /// played.
  AdBreak? takePreroll() {
    for (final AdBreak adBreak in _ordered()) {
      if (adBreak.start > prerollWindow) break;
      if (_played.add(adBreak.id)) return adBreak;
    }
    return null;
  }

  /// The break the playhead reached while playing from [previous] to
  /// [current], marked as played; null when none was reached, or when the
  /// move was a seek. With several breaks in one step (rare), only the last
  /// plays, and all of them count as played.
  AdBreak? due(Duration previous, Duration current) {
    final Duration step = current - previous;
    if (step <= Duration.zero || step > maxPlayStep) return null;
    AdBreak? reached;
    for (final AdBreak adBreak in _ordered()) {
      if (adBreak.start <= prerollWindow || _played.contains(adBreak.id)) {
        continue;
      }
      if (adBreak.start > previous && adBreak.start <= current) {
        _played.add(adBreak.id);
        reached = adBreak;
      }
    }
    return reached;
  }

  List<AdBreak> _ordered() =>
      _breaks.values.toList()
        ..sort((AdBreak a, AdBreak b) => a.start.compareTo(b.start));
}
