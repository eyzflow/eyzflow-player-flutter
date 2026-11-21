// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'eyzflow_streaming_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class EYZFlowStreamingLocalizationsDe extends EYZFlowStreamingLocalizations {
  EYZFlowStreamingLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get back => 'Zurück';

  @override
  String get rewind15Seconds => '15 Sekunden zurück';

  @override
  String get forward15Seconds => '15 Sekunden vor';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Untertitel';

  @override
  String get subtitlesOff => 'Aus';

  @override
  String get playbackUnavailable => 'Wiedergabe nicht verfügbar';

  @override
  String get unableToLoadVideo => 'Video konnte nicht geladen werden.';

  @override
  String get ok => 'OK';

  @override
  String get closePlayer => 'Player schließen';

  @override
  String get playbackNotAvailableOnPlatform =>
      'Wiedergabe ist auf dieser Plattform noch nicht verfügbar.';

  @override
  String get play => 'Abspielen';

  @override
  String get pause => 'Pause';

  @override
  String get playbackTookTooLong =>
      'Die Wiedergabe hat zu lange zum Starten gebraucht.';

  @override
  String get licenceRequestTimedOut =>
      'Die Lizenzanfrage hat zu lange gedauert.';

  @override
  String get licenceRequestNotSent =>
      'Die Lizenzanfrage konnte nicht gesendet werden.';

  @override
  String get nativePlayerErrorNoDescription =>
      'Der Player wurde ohne Fehlerbeschreibung beendet.';

  @override
  String get retryPlayback => 'Erneut versuchen';

  @override
  String get castTo => 'Streamen';

  @override
  String get castSearching => 'Geräte werden gesucht…';

  @override
  String get castNoDevices =>
      'Keine Cast-Geräte gefunden. Smartphone und Fernseher müssen im selben WLAN sein.';

  @override
  String castConnecting(String device) {
    return 'Verbindung zu $device…';
  }

  @override
  String castPlayingOn(String device) {
    return 'Wird auf $device abgespielt';
  }

  @override
  String get castStop => 'Streamen beenden';

  @override
  String castFailed(String device) {
    return 'Wiedergabe auf $device nicht möglich.';
  }
}
