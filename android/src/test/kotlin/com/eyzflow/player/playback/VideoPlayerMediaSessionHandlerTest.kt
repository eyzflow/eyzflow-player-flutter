package com.eyzflow.player.playback

import android.content.Context
import androidx.media3.common.Player
import org.junit.jupiter.api.Test
import org.mockito.Mockito.*
import kotlin.test.assertEquals

class VideoPlayerMediaSessionHandlerTest {
    private class Handle : PlaybackSessionHandle {
        var releases = 0
        var info: PlaybackMediaInfo? = null
        override fun updateMediaInfo(info: PlaybackMediaInfo) { this.info = info }
        override fun release() { releases++ }
    }
    private val player = mock(Player::class.java)
    private val created = mutableListOf<Handle>()
    private val handler = VideoPlayerMediaSessionHandler(mock(Context::class.java), 7, player) { _, _, _ ->
        Handle().also { created.add(it) }
    }

    @Test fun repeatedVisibleCreatesOneSession() {
        handler.setVisible(true)
        handler.setVisible(true)
        assertEquals(1, created.size)
    }

    @Test fun missingMetadataStillCreatesSession() {
        handler.updateMediaInfo(null)
        handler.setVisible(true)
        assertEquals("Video", created.single().info?.title)
    }

    @Test fun hiddenReleasesSession() {
        handler.setVisible(true)
        handler.setVisible(false)
        assertEquals(1, created.single().releases)
    }

    @Test fun returnCreatesSessionWithoutPlaying() {
        handler.setVisible(true)
        handler.setVisible(false)
        handler.setVisible(true)
        assertEquals(2, created.size)
        verify(player, never()).play()
    }

    @Test fun releaseIsIdempotent() {
        handler.setVisible(true)
        handler.release()
        handler.release()
        handler.setVisible(true)
        assertEquals(1, created.size)
        assertEquals(1, created.single().releases)
        verify(player, never()).release()
    }

    @Test fun latestMetadataSurvivesSessionRecreation() {
        handler.updateMediaInfo(mapOf("title" to "First film", "artworkUrl" to "https://example.com/first.jpg"))
        handler.setVisible(true)
        handler.updateMediaInfo(mapOf("title" to "Second film"))
        handler.setVisible(false)
        handler.setVisible(true)
        assertEquals(PlaybackMediaInfo("Second film", null, null), created.last().info)
    }

    @Test fun blankTitleUsesFallbackAndNeverExposesStreamCredentials() {
        handler.updateMediaInfo(mapOf("title" to " ", "licenseUrl" to "secret", "drm" to "secret"))
        handler.setVisible(true)
        assertEquals(PlaybackMediaInfo("Video", null, null), created.single().info)
    }
}
