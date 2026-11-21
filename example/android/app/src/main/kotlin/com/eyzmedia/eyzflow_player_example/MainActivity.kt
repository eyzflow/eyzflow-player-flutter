package com.eyzmedia.eyzflow_player_example

import android.app.PictureInPictureUiState
import android.content.res.Configuration
import android.os.Build
import com.eyzflow.player.playback.AndroidPlaybackHost
import io.flutter.embedding.android.FlutterActivity

// The native player only plays while the host reports the
// activity visible, so every lifecycle and PiP callback is forwarded.
class MainActivity : FlutterActivity() {
    override fun onStart() { super.onStart(); AndroidPlaybackHost.onStart(this) }
    override fun onResume() { super.onResume(); AndroidPlaybackHost.onResume(this) }
    override fun onPause() { AndroidPlaybackHost.onPause(this); super.onPause() }
    override fun onStop() { AndroidPlaybackHost.onStop(this); super.onStop() }
    override fun onUserLeaveHint() { AndroidPlaybackHost.onUserLeaveHint(this); super.onUserLeaveHint() }

    override fun onPictureInPictureUiStateChanged(pipState: PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(pipState)
        if (Build.VERSION.SDK_INT >= 35 && pipState.isTransitioningToPip) {
            AndroidPlaybackHost.onPictureInPictureTransitionStarted(this)
        }
    }

    override fun onPictureInPictureModeChanged(inPip: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(inPip, newConfig)
        AndroidPlaybackHost.onPictureInPictureModeChanged(this, inPip)
    }
}
