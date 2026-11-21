package com.eyzflow.player.playback

import androidx.media3.common.Player
import org.junit.jupiter.api.Test
import org.mockito.ArgumentCaptor
import org.mockito.Mockito.*
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class VisiblePlaybackPlayerTest {
    private val delegate = mock(Player::class.java)
    private val policy = VisiblePlaybackPolicy()
    private val player = VisiblePlaybackPlayer(delegate, policy)

    private fun visible() {
        policy.updateVisibility(true, true, false, true)
        player.enforceVisibility()
    }

    private fun hidden() {
        policy.updateVisibility(true, false, false, true)
        player.enforceVisibility()
    }

    @Test fun hiddenCommandsNeverReachPlayer() {
        player.play()
        player.playWhenReady = true
        verify(delegate, never()).play()
        verify(delegate, never()).setPlayWhenReady(true)
    }

    @Test fun visiblePlayReachesDelegate() {
        visible()
        player.play()
        player.playWhenReady = true
        verify(delegate).play()
        verify(delegate).setPlayWhenReady(true)
    }

    @Test fun hiddenPauseClearsPlayWhenReady() {
        visible()
        hidden()
        verify(delegate).setPlayWhenReady(false)
    }

    @Test fun returnDoesNotPlay() {
        visible()
        hidden()
        visible()
        verify(delegate, never()).play()
        verify(delegate, never()).setPlayWhenReady(true)
    }

    @Test fun lateReadyAfterHideAndReturnDoesNotPlay() {
        visible()
        val beforeLoad = player.intentRevision
        hidden()
        visible()
        player.playIfCurrent(beforeLoad)
        verify(delegate, never()).play()
        assertTrue(player.intentRevision > beforeLoad)
    }

    @Test fun manualPauseCancelsPendingAutoplay() {
        visible()
        val beforeLoad = player.intentRevision
        player.pause()
        player.playIfCurrent(beforeLoad)
        verify(delegate, never()).play()
    }

    @Test fun nativeInterruptionCancelsPendingAutoplay() {
        visible()
        val beforeLoad = player.intentRevision
        player.invalidatePendingPlay()
        player.playIfCurrent(beforeLoad)
        verify(delegate, never()).play()
    }

    @Test fun currentAutoplayCanPlayOnceVisible() {
        visible()
        player.playIfCurrent(player.intentRevision)
        verify(delegate).play()
    }

    @Test fun screenOffBlocksPipPlay() {
        policy.updateVisibility(true, false, true, false)
        player.enforceVisibility()
        player.play()
        verify(delegate, never()).play()
    }

    @Test fun visiblePipCanPlayWhileActivityIsStopped() {
        policy.updateVisibility(true, false, true, true)
        player.enforceVisibility()
        player.play()
        verify(delegate).play()
    }

    @Test fun closedOwnerRejectsLatePlay() {
        visible()
        val revision = player.intentRevision
        player.closePlayback()
        visible()
        player.play()
        player.playIfCurrent(revision)
        verify(delegate, never()).play()
    }

    @Test fun repeatedVisibilityDoesNotInvalidateIntent() {
        visible()
        val revision = player.intentRevision
        visible()
        assertEquals(revision, player.intentRevision)
    }

    @Test fun forwardedOnEventsUsesWrapper() {
        var reported: Player? = null
        player.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                reported = player
            }
        })
        val captor = ArgumentCaptor.forClass(Player.Listener::class.java)
        verify(delegate).addListener(captor.capture())
        captor.value.onEvents(delegate, mock(Player.Events::class.java))
        assertSame(player, reported)
    }
}
