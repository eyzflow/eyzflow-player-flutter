import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ads/ad_breaks.dart';

/// The intro, recap and credits marked on a stream in the dashboard (Stream →
/// Signals). The backend writes each one into every HLS media playlist as
///
/// ```text
/// #EXT-X-DATERANGE:ID="eyz-intro",CLASS="com.eyzflow.signal",
///   START-DATE="1970-01-01T00:00:15.000Z",DURATION=15.000,
///   X-EYZ-TYPE="intro",X-EYZ-LABEL="Main titles"
/// ```
///
/// anchored by `#EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:00:00.000Z` before the
/// first segment, so `START-DATE` minus the anchor is the position in the
/// content; and into the MPD as an `Event` of
/// `<EventStream schemeIdUri="urn:eyzflow:signal">` with
/// `messageData="intro"` or `"intro:Main titles"`.
///
/// The same rules as the web player's `stream-signals.ts`.
enum StreamSignalType {
  intro('intro'),
  recap('recap'),
  openingCredits('opening_credits'),
  closingCredits('closing_credits');

  const StreamSignalType(this.wireName);

  /// How the backend writes it: `X-EYZ-TYPE` in HLS, `messageData` in DASH.
  final String wireName;

  static StreamSignalType? fromWire(String value) {
    for (final StreamSignalType type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

/// One signal: a span of the content the viewer can skip.
@immutable
final class StreamSignal {
  const StreamSignal({
    required this.id,
    required this.type,
    required this.start,
    required this.end,
    this.label,
  });

  final String id;
  final StreamSignalType type;

  /// Position in the content where the span starts.
  final Duration start;

  /// Where the span ends: a skip lands here.
  final Duration end;

  /// The label set in the dashboard, if any. Not shown by the player.
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is StreamSignal &&
      other.id == id &&
      other.type == type &&
      other.start == start &&
      other.end == end &&
      other.label == label;

  @override
  int get hashCode => Object.hash(id, type, start, end, label);

  @override
  String toString() =>
      'StreamSignal(${type.wireName} $start–$end'
      '${label == null ? '' : ', $label'})';
}

/// The scheme of the backend's signal EventStream in an MPD.
const String dashSignalScheme = 'urn:eyzflow:signal';

/// The class the backend gives its signal DATERANGEs.
const String hlsSignalClass = 'com.eyzflow.signal';

/// Playback this close to a span's end counts as past it, so a skip that lands
/// a little short (or a span that ends at the very end of the film) doesn't
/// leave the button up.
const Duration signalEndSlack = Duration(milliseconds: 250);

final RegExp _hlsAttribute = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

Map<String, String> _hlsAttributes(String list) => <String, String>{
  for (final RegExpMatch m in _hlsAttribute.allMatches(list))
    m.group(1)!: _unquote(m.group(2)!),
};

String _unquote(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"')
    ? value.substring(1, value.length - 1)
    : value;

Duration? _seconds(String? value) {
  final double? s = value == null ? null : double.tryParse(value);
  if (s == null || s <= 0) return null;
  return Duration(microseconds: (s * Duration.microsecondsPerSecond).round());
}

String? _label(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

List<StreamSignal> _sorted(List<StreamSignal> signals) =>
    signals
      ..sort((StreamSignal a, StreamSignal b) => a.start.compareTo(b.start));

/// The signals in one HLS playlist: the `com.eyzflow.signal` DATERANGEs with a
/// known `X-EYZ-TYPE` and a positive `DURATION` (or an `END-DATE`). Without
/// the `EXT-X-PROGRAM-DATE-TIME` anchor nothing can be placed.
List<StreamSignal> parseHlsSignals(String playlist) {
  DateTime? anchor;
  final List<Map<String, String>> ranges = <Map<String, String>>[];
  for (final String raw in playlist.split('\n')) {
    final String line = raw.trim();
    if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
      anchor ??= DateTime.tryParse(line.substring(25).trim());
    } else if (line.startsWith('#EXT-X-DATERANGE:')) {
      ranges.add(_hlsAttributes(line.substring(17)));
    }
  }
  final List<StreamSignal> signals = <StreamSignal>[];
  if (anchor == null) return signals;
  final Set<String> seen = <String>{};
  for (final Map<String, String> range in ranges) {
    if (range['CLASS'] != hlsSignalClass) continue;
    final StreamSignalType? type = StreamSignalType.fromWire(
      range['X-EYZ-TYPE'] ?? '',
    );
    final DateTime? startDate = DateTime.tryParse(range['START-DATE'] ?? '');
    if (type == null || startDate == null) continue;
    final Duration start = startDate.difference(anchor);
    if (start.isNegative) continue;
    final DateTime? endDate = DateTime.tryParse(range['END-DATE'] ?? '');
    final Duration? length =
        _seconds(range['DURATION']) ?? endDate?.difference(startDate);
    if (length == null || length <= Duration.zero) continue;
    final String id = range['ID'] ?? '${type.wireName}-${start.inMilliseconds}';
    if (!seen.add(id)) continue;
    signals.add(
      StreamSignal(
        id: id,
        type: type,
        start: start,
        end: start + length,
        label: _label(range['X-EYZ-LABEL']),
      ),
    );
  }
  return _sorted(signals);
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

/// The signals in an MPD: the events of its `urn:eyzflow:signal`
/// EventStreams, with `presentationTime` and `duration` in the stream's
/// `timescale` (1 when absent), less its `presentationTimeOffset`.
List<StreamSignal> parseDashSignals(String mpd) {
  final List<StreamSignal> signals = <StreamSignal>[];
  final Set<String> seen = <String>{};
  for (final RegExpMatch stream in _eventStream.allMatches(mpd)) {
    final Map<String, String> attrs = _xmlAttributes(stream.group(1)!);
    if (attrs['schemeIdUri'] != dashSignalScheme) continue;
    final int timescale = int.tryParse(attrs['timescale'] ?? '') ?? 1;
    if (timescale <= 0) continue;
    final int offset = int.tryParse(attrs['presentationTimeOffset'] ?? '') ?? 0;
    Duration at(int ticks) =>
        Duration(microseconds: (ticks * 1000000 / timescale).round());
    for (final RegExpMatch event in _event.allMatches(stream.group(2) ?? '')) {
      final Map<String, String> e = _xmlAttributes(event.group(1)!);
      final String message = e['messageData'] ?? '';
      final int colon = message.indexOf(':');
      final StreamSignalType? type = StreamSignalType.fromWire(
        (colon == -1 ? message : message.substring(0, colon)).trim(),
      );
      final int? length = int.tryParse(e['duration'] ?? '');
      if (type == null || length == null || length <= 0) continue;
      final Duration start = at(
        (int.tryParse(e['presentationTime'] ?? '0') ?? 0) - offset,
      );
      if (start.isNegative) continue;
      final String id =
          '${type.wireName}-${e['id'] ?? start.inMilliseconds.toString()}';
      if (!seen.add(id)) continue;
      signals.add(
        StreamSignal(
          id: id,
          type: type,
          start: start,
          end: start + at(length),
          label: colon == -1 ? null : _label(message.substring(colon + 1)),
        ),
      );
    }
  }
  return _sorted(signals);
}

/// The markers of an HLS stream: its ad breaks and its signals.
typedef HlsMarkers = ({List<AdBreak> adBreaks, List<StreamSignal> signals});

const HlsMarkers noHlsMarkers = (
  adBreaks: <AdBreak>[],
  signals: <StreamSignal>[],
);

/// Reads the markers of the HLS stream at [master], the playlist the native
/// player loads: from the master itself and, when it has none, from its first
/// media playlist (the backend writes the same markers into each). A manifest
/// that cannot be loaded gives no markers.
Future<HlsMarkers> loadHlsMarkers(
  http.Client client,
  Uri master, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  HlsMarkers parse(String playlist) => (
    adBreaks: parseHlsAdBreaks(playlist),
    signals: parseHlsSignals(playlist),
  );
  try {
    final http.Response response = await client.get(master).timeout(timeout);
    if (response.statusCode != 200) return noHlsMarkers;
    final String body = response.body;
    final HlsMarkers own = parse(body);
    if (own.adBreaks.isNotEmpty ||
        own.signals.isNotEmpty ||
        !body.contains('#EXT-X-STREAM-INF')) {
      return own;
    }
    final List<Uri> media = hlsMediaPlaylistUris(body, master);
    if (media.isEmpty) return noHlsMarkers;
    final http.Response playlist = await client
        .get(media.first)
        .timeout(timeout);
    if (playlist.statusCode != 200) return noHlsMarkers;
    return parse(playlist.body);
  } on Object {
    return noHlsMarkers;
  }
}

/// The signal covering [position]; with overlapping spans, the one that
/// started last.
StreamSignal? signalAt(Iterable<StreamSignal> signals, Duration? position) {
  if (position == null) return null;
  StreamSignal? found;
  for (final StreamSignal signal in signals) {
    if (position < signal.start || position >= signal.end - signalEndSlack) {
      continue;
    }
    if (found == null || signal.start > found.start) found = signal;
  }
  return found;
}

/// The signal playback is in, from the player's position reports. Tells
/// [onStarted] and [onEnded] when playback enters or leaves one (leaving the
/// old one first when it moves straight into another).
final class SignalTracker extends ValueNotifier<StreamSignal?> {
  SignalTracker({this.onStarted, this.onEnded}) : super(null);

  void Function(StreamSignal signal)? onStarted;
  void Function(StreamSignal signal)? onEnded;

  List<StreamSignal> _signals = const <StreamSignal>[];
  Duration? _position;

  List<StreamSignal> get signals => _signals;

  /// The stream's signals, once read from the manifest.
  set signals(List<StreamSignal> signals) {
    _signals = List<StreamSignal>.unmodifiable(signals);
    _update();
  }

  /// A position report. Null (no position yet, or the content ended) leaves
  /// any signal.
  void position(Duration? position) {
    _position = position;
    _update();
  }

  void _update() {
    final StreamSignal? next = signalAt(_signals, _position);
    final StreamSignal? previous = value;
    if (next?.id == previous?.id) return;
    value = next;
    if (previous != null) onEnded?.call(previous);
    if (next != null) onStarted?.call(next);
  }
}
