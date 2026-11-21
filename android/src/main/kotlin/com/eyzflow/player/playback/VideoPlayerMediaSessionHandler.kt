package com.eyzflow.player.playback

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import com.eyzflow.player.NpLog

data class PlaybackMediaInfo(val title: String, val subtitle: String?, val artworkUrl: String?)

/** The session owns its system controls, never the shared playback engine. */
interface PlaybackSessionHandle {
    fun updateMediaInfo(info: PlaybackMediaInfo)
    fun release()
}

@UnstableApi
class VideoPlayerMediaSessionHandler(
    private val context: Context,
    private val controllerId: Int,
    private val player: Player,
    private val createSession: (Context, Player, Int) -> PlaybackSessionHandle =
        { ctx, controlledPlayer, id -> AndroidPlaybackSession(ctx, controlledPlayer, id) },
) {
    private var session: PlaybackSessionHandle? = null
    private var released = false
    private var info = PlaybackMediaInfo("Video", null, null)

    fun setVisible(visible: Boolean) {
        if (released) return
        if (!visible) {
            session?.release()
            session = null
        } else if (session == null) {
            session = createSession(context, player, controllerId).also { it.updateMediaInfo(info) }
        }
    }

    fun updateMediaInfo(info: Map<String, Any>?) {
        if (released) return
        this.info = PlaybackMediaInfo(
            (info?.get("title") as? String)?.takeIf { it.isNotBlank() } ?: "Video",
            info?.get("subtitle") as? String,
            info?.get("artworkUrl") as? String,
        )
        session?.updateMediaInfo(this.info)
    }

    fun release() {
        if (released) return
        setVisible(false)
        released = true
    }
}

/** Activity-owned session and media notification; no service is started. */
@UnstableApi
private class AndroidPlaybackSession(
    private val context: Context,
    private val player: Player,
    private val controllerId: Int,
) : PlaybackSessionHandle {
    private val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val channelId = "visible_video_playback"
    private val notificationId = 42000 + controllerId
    private val action = "${context.packageName}.VIDEO_CONTROL.$controllerId"
    private var released = false
    private var info = PlaybackMediaInfo("Video", null, null)
    private val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
        PendingIntent.getActivity(context, controllerId, it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
    private val session = MediaSession.Builder(context, player)
        .setId("eyzflow_video_$controllerId")
        .setCallback(object : MediaSession.Callback {
            override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                val commands = Player.Commands.Builder().addAll(
                    Player.COMMAND_PLAY_PAUSE,
                    Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_BACK,
                    Player.COMMAND_SEEK_FORWARD,
                    Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                    Player.COMMAND_GET_TIMELINE,
                    Player.COMMAND_GET_METADATA,
                    Player.COMMAND_GET_TRACKS,
                    Player.COMMAND_GET_AUDIO_ATTRIBUTES,
                ).build()
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                    .setAvailablePlayerCommands(commands).build()
            }
        })
        .apply { launchIntent?.let { setSessionActivity(it) } }
        .build()

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (released || intent.action != action) return
            when (intent.getStringExtra("command")) {
                "play" -> player.play()
                "pause" -> player.pause()
                "back" -> player.seekBack()
                "forward" -> player.seekForward()
            }
        }
    }
    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) { applyMetadata() }
        override fun onEvents(player: Player, events: Player.Events) { showNotification() }
    }

    init {
        if (Build.VERSION.SDK_INT >= 26) {
            notificationManager.createNotificationChannel(
                NotificationChannel(channelId, "Video playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        player.addListener(listener)
    }

    override fun updateMediaInfo(info: PlaybackMediaInfo) {
        if (released) return
        this.info = info
        applyMetadata()
        showNotification()
    }

    private fun applyMetadata() {
        if (released) return
        val item = player.currentMediaItem ?: return
        val previous = item.mediaMetadata
        val artwork = info.artworkUrl?.let(Uri::parse)
        if (previous.title == info.title && previous.artist == info.subtitle && previous.artworkUri == artwork) return
        val metadata = previous.buildUpon().setTitle(info.title).setArtist(info.subtitle)
            .setArtworkUri(artwork).build()
        // Replacing metadata preserves the URI, DRM and subtitle configurations.
        player.replaceMediaItem(player.currentMediaItemIndex, item.buildUpon().setMediaMetadata(metadata).build())
    }

    private fun action(command: String, icon: Int, title: String): Notification.Action {
        val intent = Intent(action).setPackage(context.packageName).putExtra("command", command)
        // Distinct request codes prevent Play and Pause from sharing extras.
        val pending = PendingIntent.getBroadcast(context, notificationId * 10 + command.hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Action.Builder(icon, title, pending).build()
    }

    private fun showNotification() {
        if (released) return
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channelId) else Notification.Builder(context)
        val playing = player.playWhenReady
        val notification = builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(info.title).setContentText(info.subtitle).setContentIntent(launchIntent)
            .setOnlyAlertOnce(true).setShowWhen(false).setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(action("back", android.R.drawable.ic_media_rew, "Rewind"))
            .addAction(action(if (playing) "pause" else "play", if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play, if (playing) "Pause" else "Play"))
            .addAction(action("forward", android.R.drawable.ic_media_ff, "Forward"))
            .setStyle(Notification.MediaStyle().setMediaSession(session.platformToken).setShowActionsInCompactView(0, 1, 2))
            .build()
        try {
            notificationManager.notify(notificationId, notification)
        } catch (error: SecurityException) {
            NpLog.w("MediaSession", "Media notification unavailable; session remains active")
        }
    }

    override fun release() {
        if (released) return
        released = true
        player.removeListener(listener)
        context.unregisterReceiver(receiver)
        notificationManager.cancel(notificationId)
        session.release()
    }
}
