/// The ad tag a playback requests, after the viewer's plan has had its say.
library;

/// Adds [targeting] to [adTagUrl]'s `cust_params` (Google Ad Manager's
/// custom targeting, a URL-encoded `k=v&k2=v2`), keeping any the tag already
/// has; the tag's own value wins on the same key. Returns the tag unchanged
/// when there is nothing to add or it is not an absolute URL. The rest of
/// the tag is kept as written.
String withTargeting(String adTagUrl, Map<String, String> targeting) {
  if (targeting.isEmpty) return adTagUrl;
  final Uri? uri = Uri.tryParse(adTagUrl);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return adTagUrl;

  final int hash = adTagUrl.indexOf('#');
  final String fragment = hash < 0 ? '' : adTagUrl.substring(hash);
  final String beforeFragment = hash < 0
      ? adTagUrl
      : adTagUrl.substring(0, hash);
  final int question = beforeFragment.indexOf('?');
  final String base = question < 0
      ? beforeFragment
      : beforeFragment.substring(0, question);
  final String query = question < 0
      ? ''
      : beforeFragment.substring(question + 1);

  const String name = 'cust_params';
  final segments = <String>[
    for (final segment in query.split('&'))
      if (segment.isNotEmpty) segment,
  ];
  final int at = segments.indexWhere((s) => _key(s) == name);
  final Map<String, String> params = {};
  if (at >= 0) {
    final String segment = segments[at];
    final int eq = segment.indexOf('=');
    final String existing = eq < 0 ? '' : _decode(segment.substring(eq + 1));
    params.addAll(_splitQuery(existing));
  }
  for (final MapEntry(:key, :value) in targeting.entries) {
    params.putIfAbsent(key, () => value);
  }
  final String inner = [
    for (final MapEntry(:key, :value) in params.entries)
      '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
  ].join('&');
  final String merged = '$name=${Uri.encodeQueryComponent(inner)}';
  if (at >= 0) {
    segments[at] = merged;
  } else {
    segments.add(merged);
  }
  return '$base?${segments.join('&')}$fragment';
}

/// The ad tag to request, or null for no ads at all.
///
/// [configTag] is the player config's (null when its ads are off). A
/// storefront viewer's playback session says whether their plan plays ads:
/// [planAds] false requests none, not even at the stream's markers; true or
/// null (no session, an older backend, a failed request) leaves it to the
/// config. [targeting] goes into the tag's `cust_params`.
String? planAdTag(
  String? configTag, {
  bool? planAds,
  Map<String, String> targeting = const {},
}) {
  if (configTag == null || planAds == false) return null;
  return withTargeting(configTag, targeting);
}

String? _key(String segment) {
  final int eq = segment.indexOf('=');
  return _decode(eq < 0 ? segment : segment.substring(0, eq));
}

String _decode(String component) {
  try {
    return Uri.decodeQueryComponent(component);
  } on ArgumentError {
    return component;
  } on FormatException {
    return component;
  }
}

/// `k=v&k2=v2`, in order; the first value wins on a repeated key.
Map<String, String> _splitQuery(String query) {
  final out = <String, String>{};
  for (final pair in query.split('&')) {
    if (pair.isEmpty) continue;
    final int eq = pair.indexOf('=');
    final String key = _decode(eq < 0 ? pair : pair.substring(0, eq));
    final String value = eq < 0 ? '' : _decode(pair.substring(eq + 1));
    if (key.isNotEmpty) out.putIfAbsent(key, () => value);
  }
  return out;
}
