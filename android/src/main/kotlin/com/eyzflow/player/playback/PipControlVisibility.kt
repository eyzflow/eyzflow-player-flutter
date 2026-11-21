package com.eyzflow.player.playback

/** Remembers control ownership across PiP transition and mode callbacks. */
class PipControlVisibility {
    private var beforePip: Boolean? = null

    fun update(inPip: Boolean, controlsEnabled: Boolean): Boolean {
        if (inPip) {
            if (beforePip == null) beforePip = controlsEnabled
            return false
        }
        val restored = beforePip ?: controlsEnabled
        beforePip = null
        return restored
    }
}
