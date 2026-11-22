import 'package:equatable/equatable.dart';

/// What the player plays: a trailer (never DRM-protected, not resumed) or a
/// film (DRM-protected, resumed and recorded as watch progress).
sealed class EYZFlowSourceType extends Equatable {
  const EYZFlowSourceType(this.catalogueId);

  /// The catalogue entry this stream belongs to.
  final String catalogueId;

  @override
  List<Object?> get props => [catalogueId];
}

/// A trailer: clear, played from the start, no watch progress.
final class EYZFlowTrailer extends EYZFlowSourceType {
  const EYZFlowTrailer(super.catalogueId);
}

/// A film (or episode): DRM-protected, resumed from [EYZFlowSource.progressSeconds],
/// its progress recorded against [catalogueId].
final class EYZFlowFilm extends EYZFlowSourceType {
  const EYZFlowFilm(super.catalogueId);
}

/// One EYZFlow stream, as the player plays it, with the stream and DRM URLs
/// derived from its id.
final class EYZFlowSource extends Equatable {
  const EYZFlowSource({
    required this.id,
    required this.title,
    this.description,
    this.poster,
    this.drmAccessHeader,
    this.sourceType,
    this.progressSeconds,
  });

  /// The stream id (not the catalogue id).
  final String id;
  final String title;
  final String? description;
  final Uri? poster;

  /// The DRM `access-token` header sent with licence requests. `EYZFlowPlayer`
  /// builds it; [VideoplayerFeatureView] takes it ready-made.
  final String? drmAccessHeader;

  /// A trailer or a film. Null plays as a trailer.
  final EYZFlowSourceType? sourceType;

  /// Seconds to resume from once the player knows the duration, or null to
  /// start at the beginning.
  final double? progressSeconds;

  static const String _stream = 'https://stream.eyzflow.com';
  static const String _api = 'https://api.eyzflow.com';

  Uri get hlsStreamUrl => Uri.parse('$_stream/$id/master.m3u8');

  Uri get dashStreamUrl => Uri.parse('$_stream/$id/manifest.mpd');

  Uri get fairplayCertificateUrl => Uri.parse('$_stream/fps.cer');

  Uri get fairplayLicenseUrl => Uri.parse('$_api/v1/drm/$id/fairplay/acquire');

  Uri get widevineLicenseUrl => Uri.parse('$_api/v1/drm/$id/widevine/acquire');

  /// The WebVTT thumbnail track (sprite tiles, one per 5 seconds).
  Uri get thumbnailsUrl => Uri.parse('$_stream/$id/thumbnails/thumbnail.vtt');

  EYZFlowSource copyWith({String? drmAccessHeader, double? progressSeconds}) =>
      EYZFlowSource(
        id: id,
        title: title,
        description: description,
        poster: poster,
        drmAccessHeader: drmAccessHeader ?? this.drmAccessHeader,
        sourceType: sourceType,
        progressSeconds: progressSeconds ?? this.progressSeconds,
      );

  @override
  List<Object?> get props => [
    id,
    title,
    description,
    poster,
    drmAccessHeader,
    sourceType,
    progressSeconds,
  ];
}
