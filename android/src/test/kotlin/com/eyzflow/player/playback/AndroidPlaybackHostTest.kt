package com.eyzflow.player.playback

import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AndroidPlaybackHostTest {
    private fun pip(): PlaybackHostState = PlaybackHostState().apply {
        start(); resume(); pause(); pipChanged(true)
    }

    @Test fun homeWhileBufferingStopsLateAutoplay() {
        val state = PlaybackHostState()
        state.start()
        state.stop(false)
        assertFalse(state.playbackVisible)
    }

    @Test fun expandPipPreservesOwner() {
        for (resumeFirst in listOf(true, false)) {
            val state = pip()
            if (resumeFirst) state.resume()
            assertFalse(state.pipChanged(false))
            if (!resumeFirst) state.resume()
            assertTrue(state.playbackVisible)
            assertFalse(state.stop(false)) // a later ordinary Home is not PiP dismissal
        }
    }

    @Test fun closePipReleasesOnce() {
        for (stopFirst in listOf(true, false)) {
            val state = pip()
            if (stopFirst) {
                assertFalse(state.stop(false))
                assertTrue(state.pipChanged(false))
            } else {
                assertFalse(state.pipChanged(false))
                assertTrue(state.stop(false))
            }
            assertFalse(state.pipChanged(false))
            assertFalse(state.stop(false))
            assertFalse(state.playbackVisible)
        }
    }

    @Test fun lockPipOnlyPauses() {
        val state = pip()
        state.screenInteractive = false
        assertFalse(state.stop(false))
        assertFalse(state.pipChanged(false))
        assertFalse(state.playbackVisible)
        state.screenInteractive = true
        state.start(); state.resume()
        assertTrue(state.playbackVisible)
    }

    @Test fun configurationChangeRetainsOwner() {
        val state = PlaybackHostState()
        state.start()
        assertFalse(state.stop(true))
        assertTrue(state.playbackVisible)
    }

    @Test fun disposedControllerIgnoresEvents() {
        val state = pip()
        state.close()
        state.start(); state.resume(); state.pipChanged(true)
        assertFalse(state.playbackVisible)
    }

    @Test fun tvNeverEntersPip() {
        val state = PlaybackHostState().apply { start() }
        assertFalse(state.canEnterPip(35, true, true, true))
        assertFalse(state.canEnterPip(25, false, true, true))
        assertFalse(state.canEnterPip(35, false, true, false))
        assertFalse(state.canEnterPip(35, false, false, true))
        assertTrue(state.canEnterPip(35, false, true, true))
    }

    @Test fun stoppedPipIsNotVisibleBeforeModeCallback() {
        val state = pip()
        state.stop(false)
        assertFalse(state.playbackVisible)
    }
}
