import 'package:equatable/equatable.dart';

/// What the player plays: a trailer (never DRM-protected, not resumed) or a
/// film (DRM-protected, resumed and recorded as watch progress).
sealed class EyzflowSourceType extends Equatable {
  const EyzflowSourceType(this.catalogueId);

  /// The catalogue entry this stream belongs to.
  final String catalogueId;

  @override
  List<Object?> get props => [catalogueId];
}

/// A trailer: clear, played from the start, no watch progress.
final class EyzflowTrailer extends EyzflowSourceType {
  const EyzflowTrailer(super.catalogueId);
}

/// A film (or episode): DRM-protected, resumed from [EyzflowSource.progressSeconds],
/// its progress recorded against [catalogueId].
final class EyzflowFilm extends EyzflowSourceType {
  const EyzflowFilm(super.catalogueId);
}

/// One EYZFlow stream, as the player plays it, with the stream and DRM URLs
/// derived from its id.
final class EyzflowSource extends Equatable {
  const EyzflowSource({
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

  /// The DRM `access-token` header sent with licence requests. `EyzflowPlayer`
  /// builds it; [VideoplayerFeatureView] takes it ready-made.
  final String? drmAccessHeader;

  /// A trailer or a film. Null plays as a trailer.
  final EyzflowSourceType? sourceType;

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

  EyzflowSource copyWith({String? drmAccessHeader, double? progressSeconds}) =>
      EyzflowSource(
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
