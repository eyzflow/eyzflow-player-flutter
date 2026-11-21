package com.eyzflow.player.playback

/** Native visibility is the prerequisite for every playback command. */
class VisiblePlaybackPolicy {
    private var closed = false
    private var visible = false

    val canPlay: Boolean get() = !closed && visible

    fun updateVisibility(
        routeActive: Boolean,
        activityStarted: Boolean,
        inPip: Boolean,
        screenInteractive: Boolean,
    ) {
        visible = routeActive && screenInteractive && (activityStarted || inPip)
    }

    fun close() {
        closed = true
    }
}
