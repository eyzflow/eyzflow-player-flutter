import 'dart:convert';
import 'dart:io' show Platform;

import 'package:eyzflow_player/eyzflow_player.dart';
import 'package:flutter/material.dart';

/// The storefront the form starts with: playback sessions count against its
/// plans.

void main() {
  // The language of the player's own text; the device's when not set.
  setEYZFlowPlayerLanguage('en');
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EYZFlow Player',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const LoaderPage(),
  );
}

/// A form for what [EYZFlowPlayer] takes, and a log of what it did: every
/// playback event, every beat it sent, and every limit or key refusal.
class LoaderPage extends StatefulWidget {
  const LoaderPage({super.key});

  @override
  State<LoaderPage> createState() => _LoaderPageState();
}

class _LoaderPageState extends State<LoaderPage> {
  final _streamId = TextEditingController(
    text: const String.fromEnvironment('EYZFLOW_STREAM_ID'),
  );
  final _title = TextEditingController();
  final _catalogueId = TextEditingController();
  final _bearer = TextEditingController();
  final _storefrontId = TextEditingController(
    text: const String.fromEnvironment('EYZFLOW_STOREFRONT_ID'),
  );
  final _playerKey = TextEditingController();
  final _configId = TextEditingController(
    text: const String.fromEnvironment('EYZFLOW_CONFIG_ID'),
  );
  // A VAST or VMAP tag, e.g. one of Google's IMA sample tags. Turns ads on
  // over whatever the player config says.
  final _adTagUrl = TextEditingController(
    text: const String.fromEnvironment('EYZFLOW_AD_TAG_URL'),
  );
  final _apiOrigin = TextEditingController();
  // The EYZFlow Cast receiver (cast-receiver/README.md), published unlisted.
  final _castReceiver = TextEditingController(text: 'A534F914');
  final _startAt = TextEditingController();
  // Stream ids for the end screen: the first is "Up next", the rest the row
  // of films. Empty: no end screen.
  final _endScreenIds = TextEditingController(
    text: const String.fromEnvironment('EYZFLOW_END_SCREEN_IDS'),
  );

  bool _isFeature = !const bool.fromEnvironment('EYZFLOW_TRAILER');

  // Tizen reports itself as Linux.
  bool _isTv = Platform.isLinux || const bool.fromEnvironment('EYZFLOW_TV');
  final List<String> _log = [];

  void _add(String line) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() => _log.insert(0, '$stamp  $line'));
  }

  @override
  void initState() {
    super.initState();
    // Plays the prefilled stream at once: typing on a TV remote is slow.
    if (const bool.fromEnvironment('EYZFLOW_AUTOPLAY')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  String? _orNull(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  void _play() {
    final String? id = _orNull(_streamId);
    if (id == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Stream ID is required')));
      return;
    }
    // A viewer's Cognito token (a JWT) goes out as "Bearer …" with the app's
    // licence parameters; any other value is sent as the Authorization
    // header as it is, with none.
    final String? token = _orNull(_bearer);
    final bool isViewerToken = token != null && token.startsWith('eyJ');
    final String? apiOrigin = _orNull(_apiOrigin);
    final endpoints = apiOrigin == null
        ? const EYZFlowEndpoints()
        : EYZFlowEndpoints(api: apiOrigin);
    final upload = HttpBeatSender(endpoints: endpoints);
    _add('▶ $id (${_isFeature ? 'film' : 'trailer'})');

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => EYZFlowPlayer(
          streamId: id,
          title: _orNull(_title) ?? id,
          sourceType: _isFeature
              ? EYZFlowFilm(_orNull(_catalogueId) ?? id)
              : EYZFlowTrailer(id),
          progressSeconds: double.tryParse(_startAt.text.trim()),
          isTv: _isTv,
          playerKey: _orNull(_playerKey),
          configId: _orNull(_configId),
          config: switch (_orNull(_adTagUrl)) {
            final String tag => PlayerConfigOverride(
              features: const PlayerFeaturesOverride(ads: true),
              ads: PlayerAdsConfig(adTagUrl: tag),
            ),
            null => null,
          },
          castReceiverAppId: _orNull(_castReceiver),
          drmAuthorization: isViewerToken ? 'Bearer $token' : token,
          storefrontId: isViewerToken ? _orNull(_storefrontId) : null,
          drmParameters: isViewerToken
              ? const {'source': 'internal'}
              : const <String, Object?>{},
          deviceName: _isTv ? 'Example TV' : 'Example phone',
          endpoints: endpoints,
          beatSender: (beat) async {
            final m = beat.metrics;
            _add(
              'beat #${beat.seq}${beat.isFinal ? ' final' : ''}: '
              'played ${m.playedMs} ms, stalls ${m.rebufferCount}, '
              'seeks ${m.seekCount}, pos ${m.maxPositionS.toStringAsFixed(0)} s'
              '${beat.errors.isEmpty ? '' : ', ${beat.errors.length} error(s)'}',
            );
            return upload(beat);
          },
          endScreen: _endScreen(),
          onPlaybackEvent: (event) => _add(event.toString()),
          onLimitReached: (limit) => _add(
            'limit ${limit.code.wireName}: '
            '${const JsonEncoder().convert(limit.details)}',
          ),
          onLicenseError: (error) => _add('key refused ${error.code.wireName}'),
          onError: (message) => _add('error: $message'),
        ),
      ),
    );
  }

  String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  /// The end screen from the ids in the form: placeholder titles, no
  /// posters. Picks are logged; the player plays them in place.
  EYZFlowEndScreen? _endScreen() {
    final List<String> ids = _endScreenIds.text
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return null;
    return EYZFlowEndScreen(
      nextUp: EYZFlowEndScreenItem(
        streamId: ids.first,
        title: 'Up next: ${_short(ids.first)}',
        badge: 'Next',
      ),
      items: [
        for (final (i, id) in ids.skip(1).indexed)
          EYZFlowEndScreenItem(
            streamId: id,
            title: 'Film ${i + 1} (${_short(id)})',
            duration: Duration(minutes: 80 + i * 12),
          ),
      ],
      onSelect: (selection) => _add(
        'end screen picked ${selection.item.streamId}'
        '${selection.autoplay ? ' (autoplay)' : ''}',
      ),
    );
  }

  @override
  void dispose() {
    for (final c in [
      _streamId,
      _title,
      _catalogueId,
      _bearer,
      _storefrontId,
      _playerKey,
      _configId,
      _adTagUrl,
      _apiOrigin,
      _castReceiver,
      _startAt,
      _endScreenIds,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? helper,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: controller,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, helperText: helper),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EYZFlow Player')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Film')),
              ButtonSegment(value: false, label: Text('Trailer')),
            ],
            selected: {_isFeature},
            onSelectionChanged: (value) =>
                setState(() => _isFeature = value.first),
          ),
          const SizedBox(height: 8),
          _field(_streamId, 'Stream ID', helper: 'Not the catalogue ID'),
          _field(_title, 'Title'),
          if (_isFeature) ...[
            _field(_catalogueId, 'Catalogue ID', helper: 'For watch progress'),
            _field(
              _bearer,
              'DRM authorization',
              helper:
                  "A viewer's Cognito access token (without 'Bearer'), "
                  'or a raw Authorization value',
            ),
            _field(
              _storefrontId,
              'Storefront ID',
              helper: 'Opens a playback session (stream and device limits)',
            ),
            _field(
              _startAt,
              'Start at (seconds)',
              keyboard: TextInputType.number,
            ),
          ],
          _field(
            _playerKey,
            'Player key',
            helper: 'pk_… from Player → Keys, with this app allowed',
          ),
          _field(
            _configId,
            'Player config ID',
            helper:
                'cfg_… from Player → Configs; theme and features. '
                'Empty for the defaults',
          ),
          _field(
            _adTagUrl,
            'Ad tag URL',
            helper: 'VAST or VMAP; turns ads on. Empty for the config\'s',
            keyboard: TextInputType.url,
          ),
          _field(
            _apiOrigin,
            'API origin',
            helper: 'Empty for https://api.eyzflow.com',
            keyboard: TextInputType.url,
          ),
          _field(
            _castReceiver,
            'Cast receiver app id',
            helper: 'Google Cast console; else the config\'s. Films need one',
          ),
          _field(
            _endScreenIds,
            'End screen stream IDs',
            helper: 'Comma-separated: the first is Up next, the rest the row',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('TV layout'),
            value: _isTv,
            onChanged: (value) => setState(() => _isTv = value),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _play,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Log', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_log.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
