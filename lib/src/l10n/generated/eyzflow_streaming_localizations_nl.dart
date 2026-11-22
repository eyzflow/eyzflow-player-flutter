// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'eyzflow_streaming_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Dutch Flemish (`nl`).
class EYZFlowStreamingLocalizationsNl extends EYZFlowStreamingLocalizations {
  EYZFlowStreamingLocalizationsNl([String locale = 'nl']) : super(locale);

  @override
  String get back => 'Terug';

  @override
  String get rewind15Seconds => '15 seconden terug';

  @override
  String get forward15Seconds => '15 seconden vooruit';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Ondertitels';

  @override
  String get subtitlesOff => 'Uit';

  @override
  String get playbackUnavailable => 'Afspelen niet beschikbaar';

  @override
  String get unableToLoadVideo => 'Kan video niet laden.';

  @override
  String get ok => 'OK';

  @override
  String get closePlayer => 'Speler sluiten';

  @override
  String get playbackNotAvailableOnPlatform =>
      'Afspelen is nog niet beschikbaar op dit platform.';

  @override
  String get play => 'Afspelen';

  @override
  String get pause => 'Pauzeren';

  @override
  String get playbackTookTooLong =>
      'Het duurde te lang voordat het afspelen begon.';

  @override
  String get licenceRequestTimedOut => 'De licentieaanvraag is verlopen.';

  @override
  String get licenceRequestNotSent =>
      'De licentieaanvraag kon niet worden verzonden.';

  @override
  String get nativePlayerErrorNoDescription =>
      'De speler is gestopt zonder foutbeschrijving.';

  @override
  String get retryPlayback => 'Opnieuw proberen';

  @override
  String get castTo => 'Casten';

  @override
  String get castSearching => 'Apparaten zoeken…';

  @override
  String get castNoDevices =>
      'Geen Cast-apparaten gevonden. Je telefoon en je tv moeten op hetzelfde wifi-netwerk zitten.';

  @override
  String castConnecting(String device) {
    return 'Verbinden met $device…';
  }

  @override
  String castPlayingOn(String device) {
    return 'Speelt af op $device';
  }

  @override
  String get castStop => 'Casten stoppen';

  @override
  String castFailed(String device) {
    return 'Afspelen op $device is niet gelukt.';
  }

  @override
  String adCountdown(int seconds) {
    return 'Reclame over $seconds';
  }
}
