// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'eyzflow_streaming_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class EYZFlowStreamingLocalizationsFr extends EYZFlowStreamingLocalizations {
  EYZFlowStreamingLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get back => 'Retour';

  @override
  String get rewind15Seconds => 'Reculer de 15 secondes';

  @override
  String get forward15Seconds => 'Avancer de 15 secondes';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Sous-titres';

  @override
  String get subtitlesOff => 'Désactivés';

  @override
  String get playbackUnavailable => 'Lecture indisponible';

  @override
  String get unableToLoadVideo => 'Impossible de charger la vidéo.';

  @override
  String get ok => 'OK';

  @override
  String get closePlayer => 'Fermer le lecteur';

  @override
  String get playbackNotAvailableOnPlatform =>
      'La lecture n’est pas encore disponible sur cette plateforme.';

  @override
  String get play => 'Lecture';

  @override
  String get pause => 'Pause';

  @override
  String get playbackTookTooLong =>
      'La lecture a mis trop de temps à démarrer.';

  @override
  String get licenceRequestTimedOut => 'La demande de licence a expiré.';

  @override
  String get licenceRequestNotSent =>
      'La demande de licence n’a pas pu être envoyée.';

  @override
  String get nativePlayerErrorNoDescription =>
      'Le lecteur s’est arrêté sans description de l’erreur.';

  @override
  String get retryPlayback => 'Réessayer';

  @override
  String get castTo => 'Caster';

  @override
  String get castSearching => 'Recherche d’appareils…';

  @override
  String get castNoDevices =>
      'Aucun appareil Cast trouvé. Votre téléphone et votre téléviseur doivent être sur le même réseau Wi-Fi.';

  @override
  String castConnecting(String device) {
    return 'Connexion à $device…';
  }

  @override
  String castPlayingOn(String device) {
    return 'Lecture sur $device';
  }

  @override
  String get castStop => 'Arrêter la diffusion';

  @override
  String castFailed(String device) {
    return 'Impossible de lire sur $device.';
  }
}
