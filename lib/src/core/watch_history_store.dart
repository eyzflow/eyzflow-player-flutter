import 'dart:convert';

import 'package:http/http.dart' as http;

import '../player/watch_progress_recorder.dart';
import 'api.dart';

/// Saves watch progress to the EYZFlow watch history, the store
/// [EYZFlowPlayer] uses when the app passes none:
/// `PUT /v1/content/storefront/{storefrontId}/watch-history` with the
/// viewer's `Authorization`. The web player's `eyzflowWatchHistoryStore`.
///
/// A refused or failed save throws; the recorder logs it and playback goes
/// on.
final class EYZFlowWatchHistoryStore implements WatchProgressStore {
  EYZFlowWatchHistoryStore({
    required this.storefrontId,
    required this.authorization,
    this.offerId,
    http.Client? client,
    this.endpoints = const EYZFlowEndpoints(),
  }) : _client = client ?? http.Client();

  /// The storefront the viewer watches on.
  final String storefrontId;

  /// The viewer's `Authorization` value, e.g. `Bearer <token>`.
  final String authorization;

  /// The offer (film or episode) played; sent along when set.
  final String? offerId;

  final EYZFlowEndpoints endpoints;
  final http.Client _client;

  @override
  Future<void> save({
    required String catalogueId,
    required double progressSeconds,
    required bool completed,
  }) async {
    final String? offer = offerId;
    final response = await _client.put(
      endpoints.apiUri(
        '/v1/content/storefront/${Uri.encodeComponent(storefrontId)}'
        '/watch-history',
      ),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': authorization,
      },
      body: jsonEncode({
        'catalogue_id': catalogueId,
        'progress_seconds': progressSeconds.isFinite
            ? progressSeconds.floor()
            : 0,
        'completed': completed,
        if (offer != null && offer.isNotEmpty) 'offer_id': offer,
      }),
    );
    final int status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw WatchHistoryException(status);
    }
  }
}

/// The EYZFlow watch history refused a save.
final class WatchHistoryException implements Exception {
  const WatchHistoryException(this.statusCode);

  final int statusCode;

  @override
  String toString() =>
      'WatchHistoryException: watch progress was not saved (HTTP $statusCode)';
}
