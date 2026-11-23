import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

/// VAST and VMAP, as the Tizen player reads them: what IMA does for the other
/// platforms, done in Dart because there is no IMA for Tizen.
///
/// Only what a TV can play is kept: linear ads with a media file. Companion,
/// non-linear and VPAID creatives are read past. Elements are matched by
/// their local name, so a VMAP's `vmap:` prefix (or any other) does not
/// matter.

/// Where in an ad, or in the content, something happens: a time, or a share
/// of the whole.
@immutable
sealed class VastOffset {
  const VastOffset();

  /// The offset within something [total] long. A percentage needs [total];
  /// null when it is not known.
  Duration? resolve(Duration? total);

  /// `HH:MM:SS`, `HH:MM:SS.mmm` or `n%`; null for anything else.
  static VastOffset? tryParse(String? text) {
    final String? value = text?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.endsWith('%')) {
      final double? percent = double.tryParse(
        value.substring(0, value.length - 1).trim(),
      );
      if (percent == null || percent < 0 || percent > 100) return null;
      return VastPercentOffset(percent);
    }
    final Duration? time = parseVastTime(value);
    return time == null ? null : VastTimeOffset(time);
  }
}

final class VastTimeOffset extends VastOffset {
  const VastTimeOffset(this.time);

  final Duration time;

  @override
  Duration resolve(Duration? total) => time;

  @override
  bool operator ==(Object other) =>
      other is VastTimeOffset && other.time == time;

  @override
  int get hashCode => time.hashCode;

  @override
  String toString() => 'VastTimeOffset($time)';
}

final class VastPercentOffset extends VastOffset {
  const VastPercentOffset(this.percent);

  /// 0 … 100.
  final double percent;

  @override
  Duration? resolve(Duration? total) => total == null
      ? null
      : Duration(microseconds: (total.inMicroseconds * percent / 100).round());

  @override
  bool operator ==(Object other) =>
      other is VastPercentOffset && other.percent == percent;

  @override
  int get hashCode => percent.hashCode;

  @override
  String toString() => 'VastPercentOffset($percent%)';
}

/// `HH:MM:SS` or `HH:MM:SS.mmm`, as VAST writes durations and offsets.
Duration? parseVastTime(String text) {
  final RegExpMatch? m = RegExp(
    r'^(\d+):([0-5]?\d):([0-5]?\d)(?:\.(\d{1,3}))?$',
  ).firstMatch(text.trim());
  if (m == null) return null;
  final String fraction = (m.group(4) ?? '').padRight(3, '0');
  return Duration(
    hours: int.parse(m.group(1)!),
    minutes: int.parse(m.group(2)!),
    seconds: int.parse(m.group(3)!),
    milliseconds: fraction.isEmpty ? 0 : int.parse(fraction),
  );
}

@immutable
final class VastMediaFile {
  const VastMediaFile({
    required this.url,
    required this.type,
    this.delivery,
    this.width,
    this.height,
    this.bitrate,
    this.apiFramework,
  });

  final Uri url;

  /// The MIME type, e.g. `video/mp4` or `application/x-mpegURL`.
  final String type;

  /// `progressive` or `streaming`.
  final String? delivery;
  final int? width;
  final int? height;

  /// In kbit/s.
  final int? bitrate;

  /// `VPAID` and the like: code to run, not a video to play.
  final String? apiFramework;

  bool get isHls {
    final String t = type.toLowerCase();
    return t == 'application/x-mpegurl' || t == 'application/vnd.apple.mpegurl';
  }

  bool get isMp4 => type.toLowerCase() == 'video/mp4';

  @override
  String toString() => 'VastMediaFile($type ${width}x$height $url)';
}

/// One `<Tracking>`: [event] (`start`, `firstQuartile`, `skip`, …) and the URL
/// to request when it happens. A `progress` event carries its [offset].
@immutable
final class VastTracking {
  const VastTracking({required this.event, required this.url, this.offset});

  final String event;
  final Uri url;
  final VastOffset? offset;
}

@immutable
final class VastLinear {
  const VastLinear({
    this.duration,
    this.skipOffset,
    this.mediaFiles = const <VastMediaFile>[],
    this.tracking = const <VastTracking>[],
    this.clickThrough,
    this.clickTracking = const <Uri>[],
  });

  final Duration? duration;

  /// When the viewer may skip; null for an ad that cannot be skipped.
  final VastOffset? skipOffset;
  final List<VastMediaFile> mediaFiles;
  final List<VastTracking> tracking;
  final Uri? clickThrough;
  final List<Uri> clickTracking;
}

/// One `<Ad>`: an inline ad, or a wrapper pointing at the next tag.
@immutable
final class VastAd {
  const VastAd({
    this.id,
    this.sequence,
    this.impressions = const <Uri>[],
    this.errors = const <Uri>[],
    this.linear,
    this.wrapperTagUri,
    this.followAdditionalWrappers = true,
    this.wrapperTracking = const <VastTracking>[],
  });

  final String? id;

  /// Its place in an ad pod; null for a standalone ad.
  final int? sequence;
  final List<Uri> impressions;
  final List<Uri> errors;

  /// The linear creative of an inline ad; null for a wrapper, or for an
  /// inline ad without one.
  final VastLinear? linear;

  /// A wrapper's `VASTAdTagURI`; null for an inline ad.
  final Uri? wrapperTagUri;

  /// A wrapper's `followAdditionalWrappers`.
  final bool followAdditionalWrappers;

  /// A wrapper's own tracking, fired with the ad it leads to.
  final List<VastTracking> wrapperTracking;

  bool get isWrapper => wrapperTagUri != null;
}

/// A VAST document: its ads, and the error URLs for "no ad".
@immutable
final class VastResponse {
  const VastResponse({
    this.version,
    this.ads = const <VastAd>[],
    this.errors = const <Uri>[],
  });

  final String? version;
  final List<VastAd> ads;
  final List<Uri> errors;
}

/// Where a VMAP break plays.
@immutable
sealed class VmapOffset {
  const VmapOffset();

  /// `start`, `end`, `HH:MM:SS(.mmm)` or `n%`; null for anything else
  /// (including `#n`, a position among the content's own markers).
  static VmapOffset? tryParse(String? text) {
    final String? value = text?.trim();
    if (value == null || value.isEmpty) return null;
    if (value == 'start') return const VmapStart();
    if (value == 'end') return const VmapEnd();
    final VastOffset? offset = VastOffset.tryParse(value);
    return switch (offset) {
      VastTimeOffset(:final time) when time == Duration.zero =>
        const VmapStart(),
      VastTimeOffset(:final time) => VmapTime(time),
      VastPercentOffset(:final percent) when percent == 0 => const VmapStart(),
      VastPercentOffset(:final percent) when percent == 100 => const VmapEnd(),
      VastPercentOffset(:final percent) => VmapPercent(percent),
      null => null,
    };
  }
}

final class VmapStart extends VmapOffset {
  const VmapStart();
}

final class VmapEnd extends VmapOffset {
  const VmapEnd();
}

final class VmapTime extends VmapOffset {
  const VmapTime(this.time);
  final Duration time;
}

final class VmapPercent extends VmapOffset {
  const VmapPercent(this.percent);
  final double percent;
}

/// One `<vmap:AdBreak>`: where it plays, and its ads, by URL or inline.
@immutable
final class VmapBreak {
  const VmapBreak({
    required this.offset,
    this.id,
    this.adTagUri,
    this.inlineVast,
  });

  final VmapOffset offset;
  final String? id;
  final Uri? adTagUri;
  final VastResponse? inlineVast;
}

/// What an ad tag answered.
@immutable
sealed class AdTagResponse {
  const AdTagResponse();
}

final class VastTagResponse extends AdTagResponse {
  const VastTagResponse(this.vast);
  final VastResponse vast;
}

final class VmapTagResponse extends AdTagResponse {
  const VmapTagResponse(this.breaks);
  final List<VmapBreak> breaks;
}

/// Thrown for a body that is neither VAST nor VMAP.
final class AdTagFormatException implements Exception {
  const AdTagFormatException(this.message);
  final String message;

  @override
  String toString() => 'AdTagFormatException: $message';
}

/// Reads an ad tag's answer, VAST or VMAP.
AdTagResponse parseAdTag(String body) {
  final XmlElement root = _root(body);
  return switch (root.localName) {
    'VAST' => VastTagResponse(_vast(root)),
    'VMAP' => VmapTagResponse(_vmap(root)),
    final String other => throw AdTagFormatException('unexpected <$other>'),
  };
}

/// Reads a VAST document. A VMAP is an error here: a wrapper must lead to
/// VAST.
VastResponse parseVast(String body) {
  final XmlElement root = _root(body);
  if (root.localName != 'VAST') {
    throw AdTagFormatException('expected <VAST>, got <${root.localName}>');
  }
  return _vast(root);
}

XmlElement _root(String body) {
  try {
    return XmlDocument.parse(body.trim()).rootElement;
  } on XmlException catch (error) {
    throw AdTagFormatException(error.message);
  } on StateError {
    throw const AdTagFormatException('empty document');
  }
}

VastResponse _vast(XmlElement root) => VastResponse(
  version: root.getAttribute('version'),
  ads: <VastAd>[for (final XmlElement ad in _children(root, 'Ad')) ?_ad(ad)],
  errors: _urls(_children(root, 'Error')),
);

VastAd? _ad(XmlElement ad) {
  final String? id = ad.getAttribute('id');
  final int? sequence = int.tryParse(ad.getAttribute('sequence') ?? '');
  final XmlElement? inline = _child(ad, 'InLine');
  if (inline != null) {
    return VastAd(
      id: id,
      sequence: sequence,
      impressions: _urls(_children(inline, 'Impression')),
      errors: _urls(_children(inline, 'Error')),
      linear: _firstLinear(inline),
    );
  }
  final XmlElement? wrapper = _child(ad, 'Wrapper');
  if (wrapper == null) return null;
  final Uri? tag = _url(_child(wrapper, 'VASTAdTagURI'));
  if (tag == null) return null;
  final VastLinear? linear = _firstLinear(wrapper);
  return VastAd(
    id: id,
    sequence: sequence,
    impressions: _urls(_children(wrapper, 'Impression')),
    errors: _urls(_children(wrapper, 'Error')),
    wrapperTagUri: tag,
    followAdditionalWrappers:
        wrapper.getAttribute('followAdditionalWrappers')?.trim() != 'false',
    wrapperTracking: linear?.tracking ?? const <VastTracking>[],
  );
}

VastLinear? _firstLinear(XmlElement adBody) {
  final XmlElement? creatives = _child(adBody, 'Creatives');
  if (creatives == null) return null;
  for (final XmlElement creative in _children(creatives, 'Creative')) {
    final XmlElement? linear = _child(creative, 'Linear');
    if (linear != null) return _linear(linear);
  }
  return null;
}

VastLinear _linear(XmlElement linear) {
  final XmlElement? clicks = _child(linear, 'VideoClicks');
  return VastLinear(
    duration: switch (_text(_child(linear, 'Duration'))) {
      final String d => parseVastTime(d),
      null => null,
    },
    skipOffset: VastOffset.tryParse(linear.getAttribute('skipoffset')),
    mediaFiles: <VastMediaFile>[
      for (final XmlElement file in _descendants(linear, 'MediaFile'))
        ?_mediaFile(file),
    ],
    tracking: <VastTracking>[
      for (final XmlElement t in _descendants(linear, 'Tracking'))
        ?_tracking(t),
    ],
    clickThrough: clicks == null ? null : _url(_child(clicks, 'ClickThrough')),
    clickTracking: clicks == null
        ? const <Uri>[]
        : _urls(_children(clicks, 'ClickTracking')),
  );
}

VastMediaFile? _mediaFile(XmlElement file) {
  final Uri? url = _url(file);
  final String? type = file.getAttribute('type')?.trim();
  if (url == null || type == null || type.isEmpty) return null;
  return VastMediaFile(
    url: url,
    type: type,
    delivery: file.getAttribute('delivery')?.trim(),
    width: int.tryParse(file.getAttribute('width') ?? ''),
    height: int.tryParse(file.getAttribute('height') ?? ''),
    bitrate: int.tryParse(
      file.getAttribute('bitrate') ?? file.getAttribute('maxBitrate') ?? '',
    ),
    apiFramework: file.getAttribute('apiFramework')?.trim(),
  );
}

VastTracking? _tracking(XmlElement tracking) {
  final String? event = tracking.getAttribute('event')?.trim();
  final Uri? url = _url(tracking);
  if (event == null || event.isEmpty || url == null) return null;
  return VastTracking(
    event: event,
    url: url,
    offset: VastOffset.tryParse(tracking.getAttribute('offset')),
  );
}

List<VmapBreak> _vmap(XmlElement root) => <VmapBreak>[
  for (final XmlElement adBreak in _children(root, 'AdBreak')) ?_break(adBreak),
];

VmapBreak? _break(XmlElement adBreak) {
  final String? types = adBreak.getAttribute('breakType');
  if (types != null &&
      !types.split(',').map((String t) => t.trim()).contains('linear')) {
    return null;
  }
  final VmapOffset? offset = VmapOffset.tryParse(
    adBreak.getAttribute('timeOffset'),
  );
  final XmlElement? source = _child(adBreak, 'AdSource');
  if (offset == null || source == null) return null;
  final Uri? tag = _url(_child(source, 'AdTagURI'));
  final XmlElement? data = _child(source, 'VASTAdData');
  final XmlElement? inline = data == null ? null : _child(data, 'VAST');
  if (tag == null && inline == null) return null;
  return VmapBreak(
    offset: offset,
    id: adBreak.getAttribute('breakId'),
    adTagUri: tag,
    inlineVast: inline == null ? null : _vast(inline),
  );
}

Iterable<XmlElement> _children(XmlElement parent, String name) =>
    parent.childElements.where((XmlElement e) => e.localName == name);

XmlElement? _child(XmlElement parent, String name) {
  for (final XmlElement e in _children(parent, name)) {
    return e;
  }
  return null;
}

Iterable<XmlElement> _descendants(XmlElement parent, String name) =>
    parent.descendantElements.where((XmlElement e) => e.localName == name);

/// The element's text, CDATA included, trimmed; null when empty.
String? _text(XmlElement? element) {
  final String? text = element?.innerText.trim();
  return text == null || text.isEmpty ? null : text;
}

Uri? _url(XmlElement? element) {
  final String? text = _text(element);
  if (text == null) return null;
  final Uri? url = Uri.tryParse(text);
  return url != null && (url.scheme == 'http' || url.scheme == 'https')
      ? url
      : null;
}

List<Uri> _urls(Iterable<XmlElement> elements) => <Uri>[
  for (final XmlElement e in elements) ?_url(e),
];
