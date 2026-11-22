/// The EYZFlow player for Flutter apps.
///
/// [EyzflowPlayer] plays an EYZFlow stream (AVPlay on Tizen, the native
/// player on Android and iOS) with the player key check, stream and device
/// limits, and playback quality analytics. [VideoplayerFeatureView] is the
/// player alone, for hosts that handle those themselves; the clients under
/// [EyzflowPlayer] are exported too.
library;

// The player.
export 'src/player/no_player_surface.dart';
export 'src/player/playback_event.dart';
export 'src/player/playback_target.dart';
export 'src/player/player_options.dart';
export 'src/player/subtitle_preference_store.dart'
    hide resetSubtitlePreferenceStore;
export 'src/player/tizen_device_diagnostics.dart'
    hide resetTizenDeviceDiagnostics;
export 'src/player/watch_progress_recorder.dart';
export 'src/videoplayer_feature.dart';

// Chromecast.
export 'src/cast/cast_backend.dart';
export 'src/cast/cast_controller.dart';
export 'src/cast/cast_media.dart';

// EYZFlow rules around it.
export 'src/core/access_token.dart';
export 'src/core/source.dart';
export 'src/core/analytics/beat.dart';
export 'src/core/analytics/collector.dart';
export 'src/core/analytics/transport.dart';
export 'src/core/api.dart';
export 'src/core/device_id.dart';
export 'src/core/playback_session.dart';
export 'src/core/player_config.dart';
export 'src/core/player_license.dart';
export 'src/core/thumbnails.dart';
export 'src/flutter/device_context.dart'
    show SharedPreferencesDeviceIdStore, resolvePlayerPlatform;
export 'src/flutter/error_view.dart';
export 'src/flutter/event_adapter.dart';
export 'src/flutter/eyzflow_player.dart';
export 'src/end_screen/end_screen.dart' hide PlayerOverlayScope;
export 'src/l10n/language_names.dart';
export 'src/l10n/player_language.dart';
export 'src/flutter/playback_coordinator.dart';
