package com.eyzflow.player.playback

import androidx.media3.common.Player
import org.junit.jupiter.api.Test
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.*
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackScreenAwakeTest {
    @Test fun visiblePlaybackAndBufferingStayAwakeButPauseHideEndAndDisposeRelease() {
        val player = mock(Player::class.java)
        var awake = false
        `when`(player.playWhenReady).thenReturn(true)
        `when`(player.playbackState).thenReturn(Player.STATE_READY)
        val binding = PlaybackScreenAwake(player) { awake = it }
        assertTrue(awake)
        val captor = ArgumentCaptor.forClass(Player.Listener::class.java)
        verify(player).addListener(captor.capture())
        val events = mock(Player.Events::class.java)
        fun update() = captor.value.onEvents(player, events)
        `when`(player.playbackState).thenReturn(Player.STATE_BUFFERING)
        update()
        assertTrue(awake)
        `when`(player.playWhenReady).thenReturn(false)
        update()
        assertFalse(awake)
        `when`(player.playWhenReady).thenReturn(true)
        `when`(player.playbackSuppressionReason).thenReturn(Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS)
        update()
        assertFalse(awake)
        `when`(player.playbackSuppressionReason).thenReturn(Player.PLAYBACK_SUPPRESSION_REASON_NONE)
        `when`(player.playbackState).thenReturn(Player.STATE_ENDED)
        update()
        assertFalse(awake)
        `when`(player.playbackState).thenReturn(Player.STATE_READY)
        update()
        assertTrue(awake)
        binding.dispose()
        assertFalse(awake)
        verify(player).removeListener(captor.value)
        update()
        assertFalse(awake)
    }
}
