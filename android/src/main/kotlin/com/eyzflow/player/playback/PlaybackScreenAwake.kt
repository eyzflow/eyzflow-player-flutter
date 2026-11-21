package com.eyzflow.player.playback

import androidx.media3.common.Player

/** Keeps only the attached video surface awake while visible playback is intended. */
internal class PlaybackScreenAwake(
    private val player: Player,
    private val setAwake: (Boolean) -> Unit,
) : Player.Listener {
    private var disposed = false

    init {
        player.addListener(this)
        update()
    }

    override fun onEvents(player: Player, events: Player.Events) = update()

    private fun update() {
        setAwake(!disposed && player.playWhenReady &&
            player.playbackSuppressionReason == Player.PLAYBACK_SUPPRESSION_REASON_NONE &&
            (player.playbackState == Player.STATE_READY || player.playbackState == Player.STATE_BUFFERING))
    }

    fun dispose() {
        disposed = true
        player.removeListener(this)
        setAwake(false)
    }
}
