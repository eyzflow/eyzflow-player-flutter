import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../player/player_log.dart';
import 'vast.dart';

/// Requests a tracking or error URL. Fire and forget: a failed ping never
/// holds up playback.
typedef AdPing = void Function(Uri url);

/// VAST error codes the Tizen player reports.
abstract final class VastErrorCode {
  /// The response could not be parsed.
  static const int xmlParsing = 100;

  /// A wrapper's tag did not answer in time, or failed.
  static const int wrapperTimeout = 301;

  /// Too many wrappers in a row.
  static const int wrapperLimit = 302;

  /// No ad in the response, also after a wrapper.
  static const int noAd = 303;

  /// The ad's media did not start in time.
  static const int mediaTimeout = 402;

  /// None of the ad's media files is one the TV can play.
  static const int noSupportedMedia = 403;

  /// The media file could not be played.
  static const int mediaFailed = 405;
}

/// An ad ready to play: the inline ad's creative with every wrapper's
/// impressions, errors and tracking above it merged in.
@immutable
final class PlayableAd {
  const PlayableAd({
    required this.media,
    this.id,
    this.sequence,
    this.duration,
    this.skipOffset,
    this.impressions = const <Uri>[],
    this.errors = const <Uri>[],
    this.tracking = const <VastTracking>[],
  });

  final String? id;
  final int? sequence;
  final VastMediaFile media;
  final Duration? duration;
  final VastOffset? skipOffset;
  final List<Uri> impressions;
  final List<Uri> errors;
  final List<VastTracking> tracking;

  PlayableAd _under({
    required List<Uri> impressions,
    required List<Uri> errors,
    required List<VastTracking> tracking,
    int? sequence,
  }) => PlayableAd(
    id: id,
    sequence: sequence ?? this.sequence,
    media: media,
    duration: duration,
    skipOffset: skipOffset,
    impressions: <Uri>[...impressions, ...this.impressions],
    errors: <Uri>[...errors, ...this.errors],
    tracking: <VastTracking>[...tracking, ...this.tracking],
  );
}

/// The media file a Tizen TV plays best: an MP4 delivered progressively, the
/// tallest no taller than [targetHeight] (then the highest bitrate), else the
/// smallest taller one; HLS when there is no MP4. VPAID and other code
/// creatives are never picked. Null when nothing fits.
VastMediaFile? pickMediaFile(
  Iterable<VastMediaFile> files, {
  int targetHeight = 1080,
}) {
  final List<VastMediaFile> playable = <VastMediaFile>[
    for (final VastMediaFile f in files)
      if (f.apiFramework == null &&
          (f.url.scheme == 'https' || f.url.scheme == 'http') &&
          (f.isMp4 || f.isHls))
        f,
  ];
  final List<VastMediaFile> mp4 = <VastMediaFile>[
    for (final VastMediaFile f in playable)
      if (f.isMp4 && f.delivery != 'streaming') f,
  ];
  if (mp4.isNotEmpty) {
    int byQuality(VastMediaFile a, VastMediaFile b) {
      final int h = (a.height ?? 0).compareTo(b.height ?? 0);
      return h != 0 ? h : (a.bitrate ?? 0).compareTo(b.bitrate ?? 0);
    }

    final List<VastMediaFile> fitting =
        mp4.where((VastMediaFile f) => (f.height ?? 0) <= targetHeight).toList()
          ..sort(byQuality);
    if (fitting.isNotEmpty) return fitting.last;
    return (mp4.toList()..sort(byQuality)).first;
  }
  for (final VastMediaFile f in playable) {
    if (f.isHls) return f;
  }
  return null;
}

/// Fetches ad tags and follows VAST wrappers down to playable ads.
final class VastLoader {
  VastLoader({
    required this.client,
    required this.ping,
    this.maxWrapperDepth = 5,
    this.timeout = const Duration(seconds: 8),
  });

  final http.Client client;

  /// Where error URLs go (with `[ERRORCODE]` already filled in).
  final AdPing ping;

  /// How many wrappers may lead to an inline ad. VAST asks for at least 5.
  final int maxWrapperDepth;

  /// Per request.
  final Duration timeout;

  /// Fetches and reads [tag]: VAST or VMAP. Throws when it cannot be loaded
  /// or read.
  Future<AdTagResponse> fetchTag(Uri tag) async => parseAdTag(await _get(tag));

  /// The ads [response] plays, in order: its ad pod (ads with a sequence,
  /// sorted), else its first standalone ad that resolves to something
  /// playable. Wrappers are followed. Empty when there is nothing to play;
  /// the matching error URLs have been pinged by then.
  Future<List<PlayableAd>> resolve(VastResponse response) =>
      _resolve(response, depth: 0, followWrappers: true);

  Future<List<PlayableAd>> _resolve(
    VastResponse response, {
    required int depth,
    required bool followWrappers,
  }) async {
    final List<VastAd> pod =
        response.ads.where((VastAd a) => a.sequence != null).toList()
          ..sort((VastAd a, VastAd b) => a.sequence!.compareTo(b.sequence!));
    final List<PlayableAd> ads = <PlayableAd>[];
    if (pod.isNotEmpty) {
      for (final VastAd ad in pod) {
        ads.addAll(
          await _resolveAd(ad, depth: depth, followWrappers: followWrappers),
        );
      }
    } else {
      for (final VastAd ad in response.ads) {
        ads.addAll(
          await _resolveAd(ad, depth: depth, followWrappers: followWrappers),
        );
        if (ads.isNotEmpty) break;
      }
    }
    if (ads.isEmpty) _error(response.errors, VastErrorCode.noAd);
    return ads;
  }

  Future<List<PlayableAd>> _resolveAd(
    VastAd ad, {
    required int depth,
    required bool followWrappers,
  }) async {
    final Uri? next = ad.wrapperTagUri;
    if (next == null) {
      final VastLinear? linear = ad.linear;
      if (linear == null) return const <PlayableAd>[];
      final VastMediaFile? media = pickMediaFile(linear.mediaFiles);
      if (media == null) {
        logPlayback('ad ${ad.id ?? '?'}: no media file a TV can play');
        _error(ad.errors, VastErrorCode.noSupportedMedia);
        return const <PlayableAd>[];
      }
      return <PlayableAd>[
        PlayableAd(
          id: ad.id,
          sequence: ad.sequence,
          media: media,
          duration: linear.duration,
          skipOffset: linear.skipOffset,
          impressions: ad.impressions,
          errors: ad.errors,
          tracking: linear.tracking,
        ),
      ];
    }
    if (!followWrappers || depth >= maxWrapperDepth) {
      _error(ad.errors, VastErrorCode.wrapperLimit);
      return const <PlayableAd>[];
    }
    final VastResponse inner;
    try {
      inner = parseVast(await _get(next));
    } on AdTagFormatException catch (error) {
      logPlayback('ad wrapper unreadable', error: error);
      _error(ad.errors, VastErrorCode.xmlParsing);
      return const <PlayableAd>[];
    } on Object catch (error) {
      logPlayback('ad wrapper failed', error: error);
      _error(ad.errors, VastErrorCode.wrapperTimeout);
      return const <PlayableAd>[];
    }
    final List<PlayableAd> resolved = await _resolve(
      inner,
      depth: depth + 1,
      followWrappers: ad.followAdditionalWrappers,
    );
    if (resolved.isEmpty) {
      _error(ad.errors, VastErrorCode.noAd);
      return const <PlayableAd>[];
    }
    return <PlayableAd>[
      for (final PlayableAd r in resolved)
        r._under(
          impressions: ad.impressions,
          errors: ad.errors,
          tracking: ad.wrapperTracking,
          // A wrapper in a pod keeps its place in it.
          sequence: ad.sequence,
        ),
    ];
  }

  Future<String> _get(Uri url) async {
    final http.Response response = await client
        .get(expandVastMacros(url))
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('HTTP ${response.statusCode}', url);
    }
    return response.body;
  }

  void _error(List<Uri> urls, int code) {
    for (final Uri url in urls) {
      ping(expandVastMacros(url, errorCode: code));
    }
  }
}

/// Fills in the VAST macros the Tizen player knows; others are left as they
/// are, as VAST asks.
Uri expandVastMacros(
  Uri url, {
  int? errorCode,
  Duration? adPlayhead,
  Duration? contentPlayhead,
  DateTime? now,
  int? cacheBuster,
}) {
  final String text = url.toString();
  if (!text.contains('[') && !text.contains('%5B')) return url;
  final DateTime time = now ?? DateTime.now();
  final Map<String, String> values = <String, String>{
    'CACHEBUSTING': (cacheBuster ?? time.microsecondsSinceEpoch % 100000000)
        .toString()
        .padLeft(8, '0'),
    'TIMESTAMP': Uri.encodeComponent(time.toUtc().toIso8601String()),
    'ERRORCODE': ?errorCode?.toString(),
    'ADPLAYHEAD': ?_playhead(adPlayhead),
    'CONTENTPLAYHEAD': ?_playhead(contentPlayhead),
    'MEDIAPLAYHEAD': ?_playhead(contentPlayhead),
  };
  final String expanded = text.replaceAllMapped(
    RegExp(r'(?:\[|%5B)([A-Z_]+)(?:\]|%5D)'),
    (Match m) => values[m.group(1)!] ?? m.group(0)!,
  );
  return Uri.tryParse(expanded) ?? url;
}

String? _playhead(Duration? d) {
  if (d == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  final int ms = d.inMilliseconds.remainder(1000);
  return Uri.encodeComponent(
    '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
    '${two(d.inSeconds.remainder(60))}.${ms.toString().padLeft(3, '0')}',
  );
}

/// The VAST events of one ad, each requested once.
final class VastAdTracker {
  VastAdTracker({required this.ad, required this.ping});

  final PlayableAd ad;
  final AdPing ping;
  final Set<Object> _fired = <Object>{};
  Duration _position = Duration.zero;

  /// The ad's first frame is up: impression, `creativeView` and `start`.
  void started() {
    if (!_fired.add(#impression)) return;
    for (final Uri url in ad.impressions) {
      ping(expandVastMacros(url, adPlayhead: Duration.zero));
    }
    _event('creativeView');
    _event('start');
  }

  /// Where the ad is: quartiles and `progress` offsets as they are passed.
  void progress(Duration position, Duration? duration) {
    _position = position;
    if (!_fired.contains(#impression)) return;
    final Duration? total = duration ?? ad.duration;
    if (total != null && total > Duration.zero) {
      final double share = position.inMicroseconds / total.inMicroseconds;
      if (share >= 0.25) _event('firstQuartile');
      if (share >= 0.5) _event('midpoint');
      if (share >= 0.75) _event('thirdQuartile');
    }
    for (final VastTracking t in ad.tracking) {
      if (t.event != 'progress') continue;
      final Duration? at = t.offset?.resolve(total);
      if (at != null && position >= at && _fired.add(t)) _ping(t.url);
    }
  }

  /// The ad played to its end.
  void completed() {
    progress(ad.duration ?? _position, ad.duration);
    _event('firstQuartile');
    _event('midpoint');
    _event('thirdQuartile');
    _event('complete');
  }

  void skipped() => _event('skip');

  void paused() {
    _fired.remove('resume');
    _event('pause');
  }

  void resumed() {
    if (!_fired.contains('pause')) return;
    _fired.remove('pause');
    _event('resume');
  }

  /// The ad could not be played: its error URLs with [code].
  void failed(int code) {
    if (!_fired.add(#error)) return;
    for (final Uri url in ad.errors) {
      ping(expandVastMacros(url, errorCode: code, adPlayhead: _position));
    }
  }

  void _event(String name) {
    if (!_fired.add(name)) return;
    for (final VastTracking t in ad.tracking) {
      if (t.event == name) _ping(t.url);
    }
  }

  void _ping(Uri url) => ping(expandVastMacros(url, adPlayhead: _position));
}

/// Requests tracking URLs with [client], ignoring the answer and failures.
AdPing httpAdPing(http.Client client) => (Uri url) {
  unawaited(
    client
        .get(url)
        .timeout(const Duration(seconds: 5))
        .then<void>(
          (_) {},
          onError: (Object error) =>
              logPlayback('ad ping failed: $url', error: error),
        ),
  );
};
