package com.eyzflow.player.playback

/** Reduces Activity callbacks without assuming PiP callback ordering. */
internal class PlaybackHostState {
    var screenInteractive = true
    var started = false
        private set
    var inPip = false
        private set
    private var resumed = false
    private var pipWasVisible = false
    private var closed = false

    val playbackVisible: Boolean get() = !closed && started && screenInteractive

    fun start() { if (!closed) started = true }
    fun resume() {
        if (closed) return
        started = true
        resumed = true
        if (!inPip) pipWasVisible = false
    }
    fun pause() { resumed = false }
    fun stop(changingConfigurations: Boolean): Boolean {
        if (changingConfigurations) return false
        started = false
        resumed = false
        return takeDismissal()
    }
    fun pipChanged(value: Boolean): Boolean {
        if (closed) return false
        inPip = value
        if (value) pipWasVisible = true
        else if (resumed) pipWasVisible = false
        return takeDismissal()
    }
    private fun takeDismissal(): Boolean {
        if (closed || started || inPip || !pipWasVisible || !screenInteractive) return false
        pipWasVisible = false
        return true
    }
    fun close() { closed = true; started = false }
    fun canEnterPip(apiLevel: Int, isTv: Boolean, allowed: Boolean, playWhenReady: Boolean): Boolean =
        playbackVisible && apiLevel >= 26 && !isTv && allowed && playWhenReady
}
