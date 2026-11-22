// The names before EYF-225, when the product was spelled `Eyzflow` in code.
// Kept for one release so apps can move over; removed in 0.6.0.
// ignore_for_file: camel_case_types

import 'cast/cast_controller.dart';
import 'core/api.dart';
import 'core/source.dart';
import 'end_screen/end_screen.dart';
import 'flutter/error_view.dart';
import 'flutter/eyzflow_player.dart';
import 'flutter/playback_coordinator.dart';
import 'l10n/language_names.dart';
import 'l10n/player_language.dart';

@Deprecated('Renamed to EYZFlowPlayer. Removed in 0.6.0.')
typedef EyzflowPlayer = EYZFlowPlayer;
@Deprecated('Renamed to EYZFlowPlayerErrorBuilder. Removed in 0.6.0.')
typedef EyzflowPlayerErrorBuilder = EYZFlowPlayerErrorBuilder;
@Deprecated('Renamed to EYZFlowErrorView. Removed in 0.6.0.')
typedef EyzflowErrorView = EYZFlowErrorView;
@Deprecated('Renamed to EYZFlowPlayerStatus. Removed in 0.6.0.')
typedef EyzflowPlayerStatus = EYZFlowPlayerStatus;
@Deprecated('Renamed to EYZFlowPlayerLoading. Removed in 0.6.0.')
typedef EyzflowPlayerLoading = EYZFlowPlayerLoading;
@Deprecated('Renamed to EYZFlowPlayerReady. Removed in 0.6.0.')
typedef EyzflowPlayerReady = EYZFlowPlayerReady;
@Deprecated('Renamed to EYZFlowPlayerFailed. Removed in 0.6.0.')
typedef EyzflowPlayerFailed = EYZFlowPlayerFailed;
@Deprecated('Renamed to EYZFlowPlayerFailure. Removed in 0.6.0.')
typedef EyzflowPlayerFailure = EYZFlowPlayerFailure;
@Deprecated('Renamed to EYZFlowLicenseFailure. Removed in 0.6.0.')
typedef EyzflowLicenseFailure = EYZFlowLicenseFailure;
@Deprecated('Renamed to EYZFlowLimitFailure. Removed in 0.6.0.')
typedef EyzflowLimitFailure = EYZFlowLimitFailure;
@Deprecated('Renamed to EYZFlowSource. Removed in 0.6.0.')
typedef EyzflowSource = EYZFlowSource;
@Deprecated('Renamed to EYZFlowSourceType. Removed in 0.6.0.')
typedef EyzflowSourceType = EYZFlowSourceType;
@Deprecated('Renamed to EYZFlowFilm. Removed in 0.6.0.')
typedef EyzflowFilm = EYZFlowFilm;
@Deprecated('Renamed to EYZFlowTrailer. Removed in 0.6.0.')
typedef EyzflowTrailer = EYZFlowTrailer;
@Deprecated('Renamed to EYZFlowEndpoints. Removed in 0.6.0.')
typedef EyzflowEndpoints = EYZFlowEndpoints;
@Deprecated('Renamed to EYZFlowCastController. Removed in 0.6.0.')
typedef EyzflowCastController = EYZFlowCastController;
@Deprecated('Renamed to EYZFlowEndScreen. Removed in 0.6.0.')
typedef EyzflowEndScreen = EYZFlowEndScreen;
@Deprecated('Renamed to EYZFlowEndScreenItem. Removed in 0.6.0.')
typedef EyzflowEndScreenItem = EYZFlowEndScreenItem;
@Deprecated('Renamed to EYZFlowLanguageNames. Removed in 0.6.0.')
typedef EyzflowLanguageNames = EYZFlowLanguageNames;

/// Renamed to [setEYZFlowPlayerLanguage].
@Deprecated('Renamed to setEYZFlowPlayerLanguage. Removed in 0.6.0.')
void setEyzflowPlayerLanguage(String? languageCode) =>
    setEYZFlowPlayerLanguage(languageCode);
