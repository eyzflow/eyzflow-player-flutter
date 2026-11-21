package com.eyzflow.player.playback

import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PipControlVisibilityTest {
    @Test fun transitionThenModeEntryRestoresNativeControlsOnExpansion() {
        val visibility = PipControlVisibility()
        var enabled = visibility.update(true, true)
        assertFalse(enabled)
        enabled = visibility.update(true, enabled)
        assertFalse(enabled)
        assertTrue(visibility.update(false, enabled))
    }

    @Test fun pipNeverEnablesControlsOwnedByASharedOverlay() {
        val visibility = PipControlVisibility()
        assertFalse(visibility.update(true, false))
        assertFalse(visibility.update(false, false))
    }

    @Test fun modeExitWithoutEntryPreservesCurrentControls() {
        val visibility = PipControlVisibility()
        assertTrue(visibility.update(false, true))
        assertFalse(visibility.update(false, false))
    }
}
