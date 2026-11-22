import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'eyzflow_streaming_localizations_de.dart';
import 'eyzflow_streaming_localizations_en.dart';
import 'eyzflow_streaming_localizations_fr.dart';
import 'eyzflow_streaming_localizations_nl.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of EYZFlowStreamingLocalizations
/// returned by `EYZFlowStreamingLocalizations.of(context)`.
///
/// Applications need to include `EYZFlowStreamingLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/eyzflow_streaming_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: EYZFlowStreamingLocalizations.localizationsDelegates,
///   supportedLocales: EYZFlowStreamingLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the EYZFlowStreamingLocalizations.supportedLocales
/// property.
abstract class EYZFlowStreamingLocalizations {
  EYZFlowStreamingLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static EYZFlowStreamingLocalizations of(BuildContext context) {
    return Localizations.of<EYZFlowStreamingLocalizations>(
      context,
      EYZFlowStreamingLocalizations,
    )!;
  }

  static const LocalizationsDelegate<EYZFlowStreamingLocalizations> delegate =
      _EYZFlowStreamingLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('fr'),
    Locale('nl'),
  ];

  /// Back button label for main screen
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @rewind15Seconds.
  ///
  /// In en, this message translates to:
  /// **'Rewind 15 seconds'**
  String get rewind15Seconds;

  /// No description provided for @forward15Seconds.
  ///
  /// In en, this message translates to:
  /// **'Forward 15 seconds'**
  String get forward15Seconds;

  /// Audio languages label
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audio;

  /// Subtitle languages label
  ///
  /// In en, this message translates to:
  /// **'Subtitles'**
  String get subtitles;

  /// Subtitle panel row that turns subtitles off
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get subtitlesOff;

  /// No description provided for @playbackUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Playback unavailable'**
  String get playbackUnavailable;

  /// No description provided for @unableToLoadVideo.
  ///
  /// In en, this message translates to:
  /// **'Unable to load video.'**
  String get unableToLoadVideo;

  /// Dismiss the alert
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @closePlayer.
  ///
  /// In en, this message translates to:
  /// **'Close player'**
  String get closePlayer;

  /// No description provided for @playbackNotAvailableOnPlatform.
  ///
  /// In en, this message translates to:
  /// **'Playback is not available on this platform yet.'**
  String get playbackNotAvailableOnPlatform;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @playbackTookTooLong.
  ///
  /// In en, this message translates to:
  /// **'Playback took too long to start.'**
  String get playbackTookTooLong;

  /// No description provided for @licenceRequestTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Licence request timed out.'**
  String get licenceRequestTimedOut;

  /// No description provided for @licenceRequestNotSent.
  ///
  /// In en, this message translates to:
  /// **'Licence request could not be sent.'**
  String get licenceRequestNotSent;

  /// No description provided for @nativePlayerErrorNoDescription.
  ///
  /// In en, this message translates to:
  /// **'The player stopped without an error description.'**
  String get nativePlayerErrorNoDescription;

  /// No description provided for @retryPlayback.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryPlayback;

  /// Cast button and device picker title
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get castTo;

  /// No description provided for @castSearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for devices…'**
  String get castSearching;

  /// No description provided for @castNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No Cast devices found. Your phone and your TV need to be on the same Wi-Fi.'**
  String get castNoDevices;

  /// No description provided for @castConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {device}…'**
  String castConnecting(String device);

  /// No description provided for @castPlayingOn.
  ///
  /// In en, this message translates to:
  /// **'Playing on {device}'**
  String castPlayingOn(String device);

  /// No description provided for @castStop.
  ///
  /// In en, this message translates to:
  /// **'Stop casting'**
  String get castStop;

  /// No description provided for @castFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not play on {device}.'**
  String castFailed(String device);

  /// Corner notice for the last seconds before a mid-roll ad break.
  ///
  /// In en, this message translates to:
  /// **'Ad in {seconds}'**
  String adCountdown(int seconds);

  /// Button that jumps past the intro marked on the stream.
  ///
  /// In en, this message translates to:
  /// **'Skip intro'**
  String get skipIntro;

  /// Button that jumps past the recap ("previously on") marked on the stream.
  ///
  /// In en, this message translates to:
  /// **'Skip recap'**
  String get skipRecap;

  /// Button that jumps past the opening credits marked on the stream.
  ///
  /// In en, this message translates to:
  /// **'Skip credits'**
  String get skipOpeningCredits;

  /// Button that jumps past the closing credits marked on the stream.
  ///
  /// In en, this message translates to:
  /// **'Skip credits'**
  String get skipClosingCredits;

  /// End screen: the heading of the next stream.
  ///
  /// In en, this message translates to:
  /// **'Up next'**
  String get endScreenUpNext;

  /// End screen: the play button while it counts down to the next stream.
  ///
  /// In en, this message translates to:
  /// **'Next in {seconds}'**
  String endScreenNextIn(int seconds);

  /// End screen: play the next stream now.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get endScreenPlay;

  /// End screen: stop the countdown.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get endScreenCancel;

  /// End screen: the heading of the row of films.
  ///
  /// In en, this message translates to:
  /// **'More like this'**
  String get endScreenMoreLikeThis;

  /// End screen: hide it and watch the credits.
  ///
  /// In en, this message translates to:
  /// **'Back to credits'**
  String get endScreenBackToCredits;
}

class _EYZFlowStreamingLocalizationsDelegate
    extends LocalizationsDelegate<EYZFlowStreamingLocalizations> {
  const _EYZFlowStreamingLocalizationsDelegate();

  @override
  Future<EYZFlowStreamingLocalizations> load(Locale locale) {
    return SynchronousFuture<EYZFlowStreamingLocalizations>(
      lookupEYZFlowStreamingLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'fr', 'nl'].contains(locale.languageCode);

  @override
  bool shouldReload(_EYZFlowStreamingLocalizationsDelegate old) => false;
}

EYZFlowStreamingLocalizations lookupEYZFlowStreamingLocalizations(
  Locale locale,
) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return EYZFlowStreamingLocalizationsDe();
    case 'en':
      return EYZFlowStreamingLocalizationsEn();
    case 'fr':
      return EYZFlowStreamingLocalizationsFr();
    case 'nl':
      return EYZFlowStreamingLocalizationsNl();
  }

  throw FlutterError(
    'EYZFlowStreamingLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
