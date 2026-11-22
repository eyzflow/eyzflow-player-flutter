/// Player configs made in the EYZFlow dashboard (Player → Configs), as the web
/// player reads them (`config-types.ts`, `remote-config.ts`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'api.dart';

/// The config's look. Values are CSS strings, as the dashboard stores them:
/// colours as `#rrggbb` or `rgba(…)`, the radius as `10px`.
@immutable
final class PlayerTheme {
  const PlayerTheme({
    this.accentColor = '#615fff',
    this.backgroundColor = '#0a0a0a',
    this.controlsBarColor = 'rgba(10,10,10,0.88)',
    this.textColor = '#fafafa',
    this.borderRadius = '10px',
  });

  final String accentColor;
  final String backgroundColor;
  final String controlsBarColor;
  final String textColor;
  final String borderRadius;

  /// Fields the JSON lacks, or gives as something other than a string, keep
  /// [base]'s.
  factory PlayerTheme.fromJson(
    Map<String, Object?> json, {
    PlayerTheme base = const PlayerTheme(),
  }) => base.merge(PlayerThemeOverride.fromJson(json));

  PlayerTheme merge(PlayerThemeOverride? patch) => patch == null
      ? this
      : PlayerTheme(
          accentColor: patch.accentColor ?? accentColor,
          backgroundColor: patch.backgroundColor ?? backgroundColor,
          controlsBarColor: patch.controlsBarColor ?? controlsBarColor,
          textColor: patch.textColor ?? textColor,
          borderRadius: patch.borderRadius ?? borderRadius,
        );

  Map<String, Object?> toJson() => {
    'accentColor': accentColor,
    'backgroundColor': backgroundColor,
    'controlsBarColor': controlsBarColor,
    'textColor': textColor,
    'borderRadius': borderRadius,
  };

  @override
  bool operator ==(Object other) =>
      other is PlayerTheme &&
      other.accentColor == accentColor &&
      other.backgroundColor == backgroundColor &&
      other.controlsBarColor == controlsBarColor &&
      other.textColor == textColor &&
      other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(
    accentColor,
    backgroundColor,
    controlsBarColor,
    textColor,
    borderRadius,
  );
}

/// Part of a [PlayerTheme], for an inline [PlayerConfigOverride]: the fields
/// given win, the rest keep the remote (or default) value.
@immutable
final class PlayerThemeOverride {
  const PlayerThemeOverride({
    this.accentColor,
    this.backgroundColor,
    this.controlsBarColor,
    this.textColor,
    this.borderRadius,
  });

  factory PlayerThemeOverride.fromJson(Map<String, Object?> json) =>
      PlayerThemeOverride(
        accentColor: _string(json['accentColor']),
        backgroundColor: _string(json['backgroundColor']),
        controlsBarColor: _string(json['controlsBarColor']),
        textColor: _string(json['textColor']),
        borderRadius: _string(json['borderRadius']),
      );

  final String? accentColor;
  final String? backgroundColor;
  final String? controlsBarColor;
  final String? textColor;
  final String? borderRadius;
}

/// What the player offers. Each app route honours what it can express; see
/// the README's "Player configs" section.
@immutable
final class PlayerFeatures {
  const PlayerFeatures({
    this.controls = true,
    this.autoPlay = false,
    this.muted = false,
    this.loop = false,
    this.chromecast = true,
    this.airplay = true,
    this.qualitySelector = true,
    this.captions = true,
    this.pip = true,
    this.ads = false,
    this.autoHideControls = true,
  });

  final bool controls;
  final bool autoPlay;
  final bool muted;
  final bool loop;
  final bool chromecast;
  final bool airplay;
  final bool qualitySelector;
  final bool captions;
  final bool pip;
  final bool ads;
  final bool autoHideControls;

  factory PlayerFeatures.fromJson(
    Map<String, Object?> json, {
    PlayerFeatures base = const PlayerFeatures(),
  }) => base.merge(PlayerFeaturesOverride.fromJson(json));

  PlayerFeatures merge(PlayerFeaturesOverride? patch) => patch == null
      ? this
      : PlayerFeatures(
          controls: patch.controls ?? controls,
          autoPlay: patch.autoPlay ?? autoPlay,
          muted: patch.muted ?? muted,
          loop: patch.loop ?? loop,
          chromecast: patch.chromecast ?? chromecast,
          airplay: patch.airplay ?? airplay,
          qualitySelector: patch.qualitySelector ?? qualitySelector,
          captions: patch.captions ?? captions,
          pip: patch.pip ?? pip,
          ads: patch.ads ?? ads,
          autoHideControls: patch.autoHideControls ?? autoHideControls,
        );

  Map<String, Object?> toJson() => {
    'controls': controls,
    'autoPlay': autoPlay,
    'muted': muted,
    'loop': loop,
    'chromecast': chromecast,
    'airplay': airplay,
    'qualitySelector': qualitySelector,
    'captions': captions,
    'pip': pip,
    'ads': ads,
    'autoHideControls': autoHideControls,
  };

  @override
  bool operator ==(Object other) =>
      other is PlayerFeatures &&
      other.controls == controls &&
      other.autoPlay == autoPlay &&
      other.muted == muted &&
      other.loop == loop &&
      other.chromecast == chromecast &&
      other.airplay == airplay &&
      other.qualitySelector == qualitySelector &&
      other.captions == captions &&
      other.pip == pip &&
      other.ads == ads &&
      other.autoHideControls == autoHideControls;

  @override
  int get hashCode => Object.hash(
    controls,
    autoPlay,
    muted,
    loop,
    chromecast,
    airplay,
    qualitySelector,
    captions,
    pip,
    ads,
    autoHideControls,
  );
}

/// Part of a [PlayerFeatures], for an inline [PlayerConfigOverride].
@immutable
final class PlayerFeaturesOverride {
  const PlayerFeaturesOverride({
    this.controls,
    this.autoPlay,
    this.muted,
    this.loop,
    this.chromecast,
    this.airplay,
    this.qualitySelector,
    this.captions,
    this.pip,
    this.ads,
    this.autoHideControls,
  });

  factory PlayerFeaturesOverride.fromJson(Map<String, Object?> json) =>
      PlayerFeaturesOverride(
        controls: _bool(json['controls']),
        autoPlay: _bool(json['autoPlay']),
        muted: _bool(json['muted']),
        loop: _bool(json['loop']),
        chromecast: _bool(json['chromecast']),
        airplay: _bool(json['airplay']),
        qualitySelector: _bool(json['qualitySelector']),
        captions: _bool(json['captions']),
        pip: _bool(json['pip']),
        ads: _bool(json['ads']),
        autoHideControls: _bool(json['autoHideControls']),
      );

  final bool? controls;
  final bool? autoPlay;
  final bool? muted;
  final bool? loop;
  final bool? chromecast;
  final bool? airplay;
  final bool? qualitySelector;
  final bool? captions;
  final bool? pip;
  final bool? ads;
  final bool? autoHideControls;
}

/// The config's Chromecast settings.
@immutable
final class PlayerCastConfig {
  const PlayerCastConfig({
    this.receiverAppId = '',
    this.androidReceiverCompatible,
    this.autoJoinPolicy,
  });

  factory PlayerCastConfig.fromJson(Map<String, Object?> json) =>
      PlayerCastConfig(
        receiverAppId: _string(json['receiverAppId']) ?? '',
        androidReceiverCompatible: _bool(json['androidReceiverCompatible']),
        autoJoinPolicy: _string(json['autoJoinPolicy']),
      );

  /// The Cast receiver's app id; empty means none set.
  final String receiverAppId;

  /// Web only (the Cast SDK's Android-receiver flag).
  final bool? androidReceiverCompatible;

  /// Web only (`tab_and_origin_scoped`, `origin_scoped`, `page_scoped`).
  final String? autoJoinPolicy;

  Map<String, Object?> toJson() => {
    'receiverAppId': receiverAppId,
    'androidReceiverCompatible': ?androidReceiverCompatible,
    'autoJoinPolicy': ?autoJoinPolicy,
  };
}

/// The config's ads: a VAST or VMAP tag, played when `features.ads` is on
/// (Android and iOS; see [PlayerConfig.adTagUrl]).
@immutable
final class PlayerAdsConfig {
  const PlayerAdsConfig({this.adTagUrl = ''});

  factory PlayerAdsConfig.fromJson(Map<String, Object?> json) =>
      PlayerAdsConfig(adTagUrl: _string(json['adTagUrl']) ?? '');

  final String adTagUrl;

  Map<String, Object?> toJson() => {'adTagUrl': adTagUrl};
}

/// Extra DRM access-token parameters, e.g. `{'storefront_id': '…'}`. The
/// dashboard does not store this section today; it comes from an inline
/// config, as on the web.
@immutable
final class PlayerDrmConfig {
  const PlayerDrmConfig({this.parameters = const {}});

  factory PlayerDrmConfig.fromJson(Map<String, Object?> json) =>
      PlayerDrmConfig(
        parameters: switch (json['parameters']) {
          final Map<String, Object?> map => Map.unmodifiable(map),
          _ => const {},
        },
      );

  final Map<String, Object?> parameters;

  /// `parameters.storefront_id`, when it is a non-empty string.
  String? get storefrontId => switch (parameters['storefront_id']) {
    final String id when id.isNotEmpty => id,
    _ => null,
  };

  Map<String, Object?> toJson() => {'parameters': parameters};
}

/// A player config: `GET /v1/player-configs/{configId}`, merged with an
/// inline [PlayerConfigOverride] by [mergePlayerConfig].
@immutable
final class PlayerConfig {
  const PlayerConfig({
    this.id = 'default',
    this.name = 'Default',
    this.isProtected = true,
    this.theme = const PlayerTheme(),
    this.features = const PlayerFeatures(),
    this.cast,
    this.ads,
    this.drm,
  });

  /// The web player's `DEFAULT_CONFIG`, and the backend's defaults.
  static const PlayerConfig defaults = PlayerConfig();

  /// The backend's camelCase JSON. Missing or mistyped fields keep the
  /// defaults, so an older or newer backend never stops playback.
  factory PlayerConfig.fromJson(Map<String, Object?> json) => PlayerConfig(
    id: _string(json['id']) ?? defaults.id,
    name: _string(json['name']) ?? defaults.name,
    isProtected: _bool(json['isProtected']) ?? defaults.isProtected,
    theme: switch (json['theme']) {
      final Map<String, Object?> theme => PlayerTheme.fromJson(theme),
      _ => defaults.theme,
    },
    features: switch (json['features']) {
      final Map<String, Object?> features => PlayerFeatures.fromJson(features),
      _ => defaults.features,
    },
    cast: switch (json['cast']) {
      final Map<String, Object?> cast => PlayerCastConfig.fromJson(cast),
      _ => null,
    },
    ads: switch (json['ads']) {
      final Map<String, Object?> ads => PlayerAdsConfig.fromJson(ads),
      _ => null,
    },
    drm: switch (json['drm']) {
      final Map<String, Object?> drm => PlayerDrmConfig.fromJson(drm),
      _ => null,
    },
  );

  final String id;
  final String name;

  /// Whether the config plays protected streams. The app players decide from
  /// the source type instead (`EyzflowFilm` plays with DRM).
  final bool isProtected;
  final PlayerTheme theme;
  final PlayerFeatures features;
  final PlayerCastConfig? cast;
  final PlayerAdsConfig? ads;
  final PlayerDrmConfig? drm;

  /// `cast.receiverAppId`, when set.
  /// The ad tag to play: set only when `features.ads` is on and
  /// `ads.adTagUrl` is not empty. Null means no ad request at all.
  String? get adTagUrl {
    if (!features.ads) return null;
    final String url = ads?.adTagUrl.trim() ?? '';
    return url.isEmpty ? null : url;
  }

  String? get castReceiverAppId => switch (cast?.receiverAppId) {
    final String id when id.isNotEmpty => id,
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'isProtected': isProtected,
    'theme': theme.toJson(),
    'features': features.toJson(),
    if (cast case final cast?) 'cast': cast.toJson(),
    if (ads case final ads?) 'ads': ads.toJson(),
    if (drm case final drm?) 'drm': drm.toJson(),
  };
}

/// The web player's inline `config` prop: what is given here wins over the
/// remote config.
@immutable
final class PlayerConfigOverride {
  const PlayerConfigOverride({
    this.id,
    this.name,
    this.isProtected,
    this.theme,
    this.features,
    this.cast,
    this.ads,
    this.drm,
  });

  final String? id;
  final String? name;
  final bool? isProtected;

  /// Merged field by field.
  final PlayerThemeOverride? theme;

  /// Merged field by field.
  final PlayerFeaturesOverride? features;

  /// Replaces the remote `cast` as a whole.
  final PlayerCastConfig? cast;

  /// Replaces the remote `ads` as a whole.
  final PlayerAdsConfig? ads;

  /// Its parameters are merged over the remote ones.
  final PlayerDrmConfig? drm;
}

/// The web player's `mergeConfig`: [patch] over [base]. Theme and features
/// merge field by field, `cast` and `ads` are replaced, DRM parameters merge.
PlayerConfig mergePlayerConfig(PlayerConfig base, PlayerConfigOverride? patch) {
  if (patch == null) return base;
  final PlayerDrmConfig? drm = patch.drm;
  return PlayerConfig(
    id: patch.id ?? base.id,
    name: patch.name ?? base.name,
    isProtected: patch.isProtected ?? base.isProtected,
    theme: base.theme.merge(patch.theme),
    features: base.features.merge(patch.features),
    cast: patch.cast ?? base.cast,
    ads: patch.ads ?? base.ads,
    drm: drm == null
        ? base.drm
        : PlayerDrmConfig(
            parameters: Map.unmodifiable({
              ...?base.drm?.parameters,
              ...drm.parameters,
            }),
          ),
  );
}

/// Loads player configs from `GET {api}/v1/player-configs/{configId}`, a
/// public endpoint (no auth; the backend sends `Cache-Control: public,
/// max-age=60` and 404 for an unknown id).
///
/// Like the web player, a loaded config is kept in memory for the life of the
/// app, per API origin and config id; a failure is not kept, so the next
/// player tries again.
final class PlayerConfigClient {
  PlayerConfigClient({
    required this._client,
    this.endpoints = const EyzflowEndpoints(),
    this.timeout = const Duration(seconds: 5),
  });

  final http.Client _client;
  final EyzflowEndpoints endpoints;

  /// How long playback waits for the config before it starts with the
  /// defaults.
  final Duration timeout;

  static final Map<Uri, PlayerConfig> _cache = {};

  /// Forgets every loaded config.
  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// The config, from the cache when it was loaded before. Throws
  /// [PlayerConfigException] when it cannot be loaded.
  Future<PlayerConfig> fetch(String configId) async {
    final Uri uri = endpoints.apiUri(
      '/v1/player-configs/${Uri.encodeComponent(configId)}',
    );
    final PlayerConfig? cached = _cache[uri];
    if (cached != null) return cached;
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
    } on Object catch (error) {
      throw PlayerConfigException(configId, '$error');
    }
    if (response.statusCode != 200) {
      throw PlayerConfigException(configId, 'HTTP ${response.statusCode}');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw PlayerConfigException(configId, 'not JSON: ${error.message}');
    }
    if (json is! Map<String, Object?>) {
      throw PlayerConfigException(configId, 'not a JSON object');
    }
    return _cache[uri] = PlayerConfig.fromJson(json);
  }

  /// [fetch], or null when the config cannot be loaded: playback then goes on
  /// with the defaults, as on the web.
  Future<PlayerConfig?> load(String configId) async {
    try {
      return await fetch(configId);
    } on PlayerConfigException {
      return null;
    }
  }
}

/// A player config could not be loaded.
final class PlayerConfigException implements Exception {
  const PlayerConfigException(this.configId, this.reason);

  final String configId;
  final String reason;

  @override
  String toString() =>
      'PlayerConfigException: failed to load player config "$configId": '
      '$reason';
}

String? _string(Object? value) => value is String ? value : null;
bool? _bool(Object? value) => value is bool ? value : null;
