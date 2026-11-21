package com.eyzflow.player.playback

import android.app.Activity
import android.app.KeyguardManager
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.util.Rational
import androidx.core.content.ContextCompat
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import com.eyzflow.player.EyzflowPlayerPlugin
import com.eyzflow.player.NpLog
import com.eyzflow.player.manager.SharedPlayerManager

/** Activity lifecycle is native authority; Flutter supplies only route eligibility. */
@UnstableApi
object AndroidPlaybackHost {
    private class Entry(
        val player: VisiblePlaybackPlayer,
        val session: VideoPlayerMediaSessionHandler,
        var allowsPip: Boolean,
        var autoPip: Boolean,
    ) {
        var routeActive = true
        var eligible = false
        var applyingVisibility = false
        lateinit var listener: Player.Listener
    }
    private val entries = mutableMapOf<Int, Entry>()
    private var activity: Activity? = null
    private var state = PlaybackHostState()
    private var pipControllerId: Int? = null
    private var receiverContext: Context? = null
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            state.screenInteractive = intent.action != Intent.ACTION_SCREEN_OFF && isScreenInteractive(context)
            applyVisibility()
        }
    }

    fun attach(activity: Activity) {
        this.activity = activity
        state.screenInteractive = isScreenInteractive(activity)
        if (receiverContext == null) {
            val context = activity.applicationContext
            ContextCompat.registerReceiver(context, screenReceiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_USER_PRESENT)
                }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverContext = context
        }
        applyVisibility()
    }

    fun detach(activity: Activity, changingConfigurations: Boolean) {
        if (this.activity !== activity) return
        this.activity = null
        if (!changingConfigurations) {
            state.stop(false)
            applyVisibility()
            receiverContext?.unregisterReceiver(screenReceiver)
            receiverContext = null
            state = PlaybackHostState()
            pipControllerId = null
        }
    }

    fun onStart(activity: Activity) {
        if (this.activity !== activity) attach(activity)
        state.screenInteractive = isScreenInteractive(activity)
        state.start()
        applyVisibility()
    }

    fun onResume(activity: Activity) {
        if (this.activity !== activity) attach(activity)
        state.screenInteractive = isScreenInteractive(activity)
        state.resume()
        if (!state.inPip) {
            // Also recover controls if an entering PiP transition was cancelled.
            pipControllerId?.let { id ->
                EyzflowPlayerPlugin.getAllViews().filter { it.playbackControllerId == id }
                    .forEach { it.setPictureInPictureMode(false) }
            }
            pipControllerId = null
        }
        applyVisibility()
    }

    fun onPause(activity: Activity) {
        if (this.activity === activity) state.pause()
    }

    fun onStop(activity: Activity) {
        if (this.activity !== activity) return
        state.screenInteractive = isScreenInteractive(activity)
        val dismissed = state.stop(activity.isChangingConfigurations)
        applyVisibility()
        if (dismissed) closePip()
    }

    fun onPictureInPictureTransitionStarted(activity: Activity) {
        if (this.activity !== activity) return
        val id = pipControllerId ?: activeEntry()?.key ?: return
        pipControllerId = id
        // Android 15+ calls this at animation start; modeChanged arrives too late.
        // Only change native UI here, not playback eligibility or Flutter state.
        EyzflowPlayerPlugin.getAllViews().filter { it.playbackControllerId == id }
            .forEach { it.setPictureInPictureMode(true) }
    }

    fun onPictureInPictureModeChanged(activity: Activity, inPip: Boolean) {
        if (this.activity !== activity) return
        if (inPip && pipControllerId == null) pipControllerId = activeEntry()?.key
        val id = pipControllerId
        state.screenInteractive = isScreenInteractive(activity)
        val dismissed = state.pipChanged(inPip)
        id?.let {
            EyzflowPlayerPlugin.getAllViews().filter { view -> view.playbackControllerId == it }
                .forEach { view -> view.setPictureInPictureMode(inPip) }
            SharedPlayerManager.sendControllerEvent(it, if (inPip) "pipStart" else "pipStop")
        }
        applyVisibility()
        if (dismissed) closePip()
    }

    fun registerController(id: Int, player: VisiblePlaybackPlayer, session: VideoPlayerMediaSessionHandler,
                           allowsPip: Boolean, autoPip: Boolean) {
        if (entries.containsKey(id)) return
        val entry = Entry(player, session, allowsPip, autoPip)
        entry.listener = object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                if (!playWhenReady && !entry.applyingVisibility) {
                    entry.player.invalidatePendingPlay()
                    val pauseReason = when (reason) {
                        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> "audioFocus"
                        Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> "noisy"
                        else -> "user"
                    }
                    sendPause(id, entry, pauseReason)
                }
                updatePipParameters()
            }
            override fun onPlaybackSuppressionReasonChanged(reason: Int) {
                if (reason != Player.PLAYBACK_SUPPRESSION_REASON_NONE) sendPause(id, entry, "audioFocus")
            }
            override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) { updatePipParameters() }
            override fun onPlayerError(error: PlaybackException) {
                entry.routeActive = false
                applyVisibility()
            }
        }
        entries[id] = entry
        player.addListener(entry.listener)
        applyVisibility()
    }

    fun unregisterController(id: Int) {
        val entry = entries.remove(id) ?: return
        entry.player.removeListener(entry.listener)
        entry.player.closePlayback()
        entry.session.release()
        if (pipControllerId == id) pipControllerId = null
        updatePipParameters()
    }

    fun setRouteActive(controllerId: Int, active: Boolean) {
        entries[controllerId]?.routeActive = active
        applyVisibility()
    }

    fun setPipPolicy(controllerId: Int, allowsPip: Boolean, autoPip: Boolean) {
        entries[controllerId]?.let { it.allowsPip = allowsPip; it.autoPip = autoPip }
        updatePipParameters()
    }

    fun isPipAvailable(controllerId: Int): Boolean {
        val host = activity ?: return false
        val entry = entries[controllerId] ?: return false
        return entry.allowsPip && Build.VERSION.SDK_INT >= 26 && !isTv(host) &&
            host.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    fun isInPip(controllerId: Int): Boolean = state.inPip && pipControllerId == controllerId

    fun onUserLeaveHint(activity: Activity) {
        if (this.activity !== activity || Build.VERSION.SDK_INT >= 31) return
        val entry = activeEntry() ?: return
        if (entry.value.autoPip) enterPip(entry.key)
    }

    fun enterPip(controllerId: Int): Boolean {
        val host = activity ?: return false
        val entry = entries[controllerId] ?: return false
        if (!canEnterPip(host, entry)) return false
        if (Build.VERSION.SDK_INT < 26) return false
        pipControllerId = controllerId
        return try {
            host.enterPictureInPictureMode(parameters(host, controllerId, entry, false))
        } catch (error: IllegalStateException) {
            NpLog.w("PlaybackHost", "PiP unavailable; hidden playback will pause")
            false
        } catch (error: IllegalArgumentException) {
            false
        }
    }

    private fun activeEntry() = entries.entries.lastOrNull { it.value.routeActive }

    private fun canEnterPip(host: Activity, entry: Entry): Boolean =
        state.canEnterPip(Build.VERSION.SDK_INT, isTv(host), entry.routeActive && entry.allowsPip,
            entry.player.playWhenReady && entry.player.playerError == null) &&
            host.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun updatePipParameters() {
        val host = activity ?: return
        if (Build.VERSION.SDK_INT < 26 || isTv(host)) return
        val active = activeEntry()
        try {
            val params = if (active == null) PictureInPictureParams.Builder().apply {
                if (Build.VERSION.SDK_INT >= 31) setAutoEnterEnabled(false)
            }.build() else parameters(host, active.key, active.value, active.value.autoPip && canEnterPip(host, active.value))
            host.setPictureInPictureParams(params)
        } catch (error: IllegalStateException) {
            NpLog.w("PlaybackHost", "PiP parameters unavailable")
        } catch (error: IllegalArgumentException) {
            NpLog.w("PlaybackHost", "PiP parameters rejected")
        }
    }

    private fun parameters(host: Activity, id: Int, entry: Entry, autoEnter: Boolean): PictureInPictureParams {
        val size = entry.player.videoSize
        val aspect = if (size.width > 0 && size.height > 0) size.width.toFloat() * size.pixelWidthHeightRatio / size.height else 16f / 9f
        val ratio = aspect.coerceIn(1f / 2.39f, 2.39f)
        return PictureInPictureParams.Builder().setAspectRatio(Rational((ratio * 1000).toInt(), 1000)).apply {
            EyzflowPlayerPlugin.getAllViews().firstOrNull { it.playbackControllerId == id }
                ?.videoBounds()?.let { setSourceRectHint(it) }
            if (Build.VERSION.SDK_INT >= 31) setAutoEnterEnabled(autoEnter)
        }.build()
    }

    private fun applyVisibility() {
        entries.forEach { (id, entry) ->
            val visible = entry.routeActive && state.playbackVisible
            entry.applyingVisibility = true
            entry.player.policy.updateVisibility(entry.routeActive, state.started,
                state.inPip && state.started && pipControllerId == id, state.screenInteractive)
            entry.player.enforceVisibility()
            entry.applyingVisibility = false
            if (entry.eligible && !visible) sendPause(id, entry, if (state.screenInteractive) "hidden" else "screenOff")
            entry.eligible = visible
            entry.session.setVisible(visible)
        }
        updatePipParameters()
    }

    private fun sendPause(id: Int, entry: Entry, reason: String) {
        SharedPlayerManager.sendControllerEvent(id, "playbackPaused",
            mapOf("reason" to reason, "positionMs" to entry.player.currentPosition))
    }

    private fun closePip() {
        val id = pipControllerId ?: return
        val entry = entries[id] ?: return
        val context = activity?.applicationContext ?: return
        pipControllerId = null
        SharedPlayerManager.sendControllerEvent(id, "playbackClosed",
            mapOf("reason" to "pipDismissed", "positionMs" to entry.player.currentPosition))
        SharedPlayerManager.removePlayer(context, id)
    }

    private fun isScreenInteractive(context: Context): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive &&
            !(context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked

    private fun isTv(context: Context): Boolean = context.packageManager.run {
        hasSystemFeature(PackageManager.FEATURE_LEANBACK) || hasSystemFeature("android.hardware.type.television")
    }
}
