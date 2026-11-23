// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'eyzflow_streaming_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class EYZFlowStreamingLocalizationsEn extends EYZFlowStreamingLocalizations {
  EYZFlowStreamingLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get back => 'Back';

  @override
  String get rewind15Seconds => 'Rewind 15 seconds';

  @override
  String get forward15Seconds => 'Forward 15 seconds';

  @override
  String get audio => 'Audio';

  @override
  String get subtitles => 'Subtitles';

  @override
  String get subtitlesOff => 'Off';

  @override
  String get playbackUnavailable => 'Playback unavailable';

  @override
  String get unableToLoadVideo => 'Unable to load video.';

  @override
  String get ok => 'OK';

  @override
  String get closePlayer => 'Close player';

  @override
  String get playbackNotAvailableOnPlatform =>
      'Playback is not available on this platform yet.';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get playbackTookTooLong => 'Playback took too long to start.';

  @override
  String get licenceRequestTimedOut => 'Licence request timed out.';

  @override
  String get licenceRequestNotSent => 'Licence request could not be sent.';

  @override
  String get nativePlayerErrorNoDescription =>
      'The player stopped without an error description.';

  @override
  String get retryPlayback => 'Retry';

  @override
  String get castTo => 'Cast';

  @override
  String get castSearching => 'Looking for devices…';

  @override
  String get castNoDevices =>
      'No Cast devices found. Your phone and your TV need to be on the same Wi-Fi.';

  @override
  String castConnecting(String device) {
    return 'Connecting to $device…';
  }

  @override
  String castPlayingOn(String device) {
    return 'Playing on $device';
  }

  @override
  String get castStop => 'Stop casting';

  @override
  String castFailed(String device) {
    return 'Could not play on $device.';
  }

  @override
  String adCountdown(int seconds) {
    return 'Ad in $seconds';
  }

  @override
  String get skipIntro => 'Skip intro';

  @override
  String get skipRecap => 'Skip recap';

  @override
  String get skipOpeningCredits => 'Skip credits';

  @override
  String get skipClosingCredits => 'Skip credits';

  @override
  String get endScreenUpNext => 'Up next';

  @override
  String endScreenNextIn(int seconds) {
    return 'Next in $seconds';
  }

  @override
  String get endScreenPlay => 'Play';

  @override
  String get endScreenCancel => 'Cancel';

  @override
  String get endScreenMoreLikeThis => 'More like this';

  @override
  String get endScreenBackToCredits => 'Back to credits';

  @override
  String adPosition(int index, int count) {
    return 'Ad $index of $count';
  }

  @override
  String get adSkip => 'Skip ad';

  @override
  String adSkipIn(int seconds) {
    return 'Skip in $seconds';
  }
}
