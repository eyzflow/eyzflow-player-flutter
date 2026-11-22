import '../l10n/language_names.dart';
import 'package:http/http.dart' as http;

import 'player_log.dart';
import 'player_policy.dart';

/// RFC 8216 §4.3.4.2.1 accessibility UTIs carried in `CHARACTERISTICS`.
const String hlsTranscribesSpokenDialog =
    'public.accessibility.transcribes-spoken-dialog';
const String hlsDescribesMusicAndSound =
    'public.accessibility.describes-music-and-sound';
const String hlsDescribesVideo = 'public.accessibility.describes-video';
const String hlsEasyToRead = 'public.easy-to-read';

/// One `EXT-X-MEDIA` rendition of a master playlist.
///
/// Neither native plugin hands `CHARACTERISTICS` up to Dart — AVPlay's text
/// track carries only a language, and the native player drops
/// Media3's role flags — so the master playlist is read here instead.
typedef HlsRendition = ({
  String type,
  String? language,
  String? name,
  Set<String> characteristics,
  int? channels,
});

/// The `AUDIO` and `SUBTITLES` renditions of [playlist], in playlist order.
List<HlsRendition> parseHlsRenditions(String playlist) => <HlsRendition>[
  for (final String line in playlist.split(RegExp(r'\r?\n')))
    if (line.startsWith('#EXT-X-MEDIA:'))
      if (_attributes(line.substring('#EXT-X-MEDIA:'.length)) case final a
          when a['TYPE'] == 'AUDIO' || a['TYPE'] == 'SUBTITLES')
        (
          type: a['TYPE']!,
          language: a['LANGUAGE'],
          name: a['NAME'],
          characteristics: <String>{
            for (final String uti in (a['CHARACTERISTICS'] ?? '').split(','))
              if (uti.trim().isNotEmpty) uti.trim(),
          },
          // §4.3.4.1: a slash-separated list whose first parameter is the
          // count of independent channels ("6" is 5.1). Later parameters
          // ("16/JOC") are ignored.
          channels: int.tryParse((a['CHANNELS'] ?? '').split('/').first),
        ),
];

/// Parses an attribute-list (§4.2). Quoted strings may contain commas, which
/// `CHARACTERISTICS` always does when it lists more than one UTI.
Map<String, String> _attributes(String list) => <String, String>{
  for (final RegExpMatch m in RegExp(
    r'([A-Z0-9-]+)=("[^"]*"|[^,]*)',
  ).allMatches(list))
    m[1]!: m[2]!.startsWith('"') ? m[2]!.substring(1, m[2]!.length - 1) : m[2]!,
};

/// The rendition for each of [languages] — the native tracks of one [type],
/// in native order — or `null` where none matches.
///
/// Matched by language and occurrence: the Nth native `de` subtitle is the
/// Nth `de` `SUBTITLES` rendition. Both players enumerate renditions in
/// playlist order, and language is the only field both plugins report.
// ponytail: occurrence matching; if a plugin ever reorders renditions,
// match on NAME (Android's displayName) instead.
List<HlsRendition?> hlsRenditionsFor(
  String type,
  List<String> languages,
  List<HlsRendition> renditions,
) {
  final Map<String, List<HlsRendition>> byLanguage =
      <String, List<HlsRendition>>{};
  for (final HlsRendition r in renditions) {
    if (r.type == type) {
      (byLanguage[_normalized(r.language)] ??= <HlsRendition>[]).add(r);
    }
  }
  final Map<String, int> seen = <String, int>{};
  return <HlsRendition?>[
    for (final String language in languages)
      () {
        final String key = _normalized(language);
        final int n = seen[key] = (seen[key] ?? -1) + 1;
        final List<HlsRendition> matches = byLanguage[key] ?? const [];
        return n < matches.length ? matches[n] : null;
      }(),
  ];
}

/// Compared by resolved name, as the subtitle preference is: `deu`, `de` and
/// `de_DE` name one language, and Media3 rewrites three-letter codes to two.
String _normalized(String? language) =>
    EYZFlowLanguageNames.languageName(language ?? '') ?? (language ?? '');

/// Stamps each native track with its rendition's characteristics and channel count, read from
/// the [master] playlist. A failed fetch leaves tracks as they
/// were: labels are an accessibility aid, never a reason to block playback.
Future<({List<PlayerAudioTrack> audio, List<PlayerTextTrack> text})>
annotateHlsTracks(
  Uri master,
  List<PlayerAudioTrack> audio,
  List<PlayerTextTrack> text, {
  http.Client? client,
}) async {
  List<HlsRendition> renditions = const <HlsRendition>[];
  try {
    final http.Response response =
        await (client?.get(master) ?? http.get(master));
    if (response.statusCode == 200) {
      renditions = parseHlsRenditions(response.body);
    }
  } on Object catch (error) {
    logPlayback('master playlist unavailable', error: error);
  }
  final List<HlsRendition?> audioMatch = hlsRenditionsFor('AUDIO', <String>[
    for (final PlayerAudioTrack t in audio) t.language,
  ], renditions);
  final List<HlsRendition?> textMatch = hlsRenditionsFor('SUBTITLES', <String>[
    for (final PlayerTextTrack t in text) t.language,
  ], renditions);
  return (
    audio: <PlayerAudioTrack>[
      for (final (int i, PlayerAudioTrack t) in audio.indexed)
        PlayerAudioTrack(
          trackId: t.trackId,
          language: t.language,
          // The playlist is authoritative; Media3 reports no channel count.
          channel: audioMatch[i]?.channels ?? t.channel,
          characteristics: audioMatch[i]?.characteristics ?? const <String>{},
        ),
    ],
    text: <PlayerTextTrack>[
      for (final (int i, PlayerTextTrack t) in text.indexed)
        PlayerTextTrack(
          trackId: t.trackId,
          language: t.language,
          characteristics: textMatch[i]?.characteristics ?? const <String>{},
        ),
    ],
  );
}
