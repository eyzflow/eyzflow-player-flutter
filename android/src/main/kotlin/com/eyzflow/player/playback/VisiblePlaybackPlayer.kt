package com.eyzflow.player.playback

import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi

/** All controls share this gate; a stale command cannot restart hidden audio. */
@UnstableApi
class VisiblePlaybackPlayer(
    private val delegate: Player,
    val policy: VisiblePlaybackPolicy,
) : ForwardingPlayer(delegate) {
    var intentRevision: Long = 0
        private set
    private var wasEligible = policy.canPlay

    override fun play() {
        if (!policy.canPlay) return
        intentRevision++
        delegate.play()
    }

    override fun pause() {
        intentRevision++
        delegate.pause()
    }

    override fun setPlayWhenReady(playWhenReady: Boolean) {
        if (playWhenReady && !policy.canPlay) return
        intentRevision++
        delegate.playWhenReady = playWhenReady
    }

    fun invalidatePendingPlay() {
        intentRevision++
    }

    fun playIfCurrent(revision: Long) {
        if (revision == intentRevision && policy.canPlay) play()
    }

    fun enforceVisibility() {
        val eligible = policy.canPlay
        if (wasEligible && !eligible) {
            intentRevision++
            delegate.playWhenReady = false
        }
        wasEligible = eligible
    }

    fun closePlayback() {
        policy.close()
        intentRevision++
        delegate.playWhenReady = false
        wasEligible = false
    }
}
