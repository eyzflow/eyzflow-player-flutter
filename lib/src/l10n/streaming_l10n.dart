import 'dart:ui' show Locale;

import 'generated/eyzflow_streaming_localizations.dart';
import 'player_language.dart';

/// The player's own text in [eyzflowPlayerLanguage]. Player policies and
/// clients have no `BuildContext`, so widgets use the same accessor.
EYZFlowStreamingLocalizations get streamingL10n =>
    lookupEYZFlowStreamingLocalizations(Locale(eyzflowPlayerLanguage));
