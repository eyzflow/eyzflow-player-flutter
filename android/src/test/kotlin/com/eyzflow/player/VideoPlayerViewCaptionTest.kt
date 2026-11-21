package com.eyzflow.player

import android.content.Context
import android.view.accessibility.CaptioningManager
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import com.eyzflow.player.playback.PipControlVisibility
import org.junit.jupiter.api.Test
import org.mockito.AdditionalMatchers
import org.mockito.Mockito.*

class VideoPlayerViewCaptionTest {
    @Test fun pipExitRestoresSystemCaptionSizeOnBothDisplayPaths() {
        for (lightweight in listOf(false, true)) {
            val (view, captions) = fixture(lightweight, 1f)
            view.setPictureInPictureMode(true)
            clearInvocations(captions)

            view.setPictureInPictureMode(false)

            verify(captions).setUserDefaultTextSize()
            verify(captions, never()).setFractionalTextSize(anyFloat())
        }
    }

    @Test fun pipExitCombinesCustomScaleWithSystemCaptionPreference() {
        for (lightweight in listOf(false, true)) {
            val (view, captions) = fixture(lightweight, 1.5f)
            view.setPictureInPictureMode(true)
            clearInvocations(captions)

            view.setPictureInPictureMode(false)

            // Media3's default 0.0533 × Android's 2× preference × app's 1.5× scale.
            verify(captions).setFractionalTextSize(AdditionalMatchers.eq(0.1599f, 0.000001f))
        }
    }

    private fun fixture(lightweight: Boolean, scale: Float): Pair<VideoPlayerView, SubtitleView> {
        // Exercise the real PiP method without constructing an ExoPlayer or Android window.
        val view = mock(VideoPlayerView::class.java, CALLS_REAL_METHODS)
        val captions = mock(SubtitleView::class.java)
        val session = mock(PlayerBackendSession::class.java)
        `when`(session.embeddedTextScale).thenReturn(scale)
        val context = mock(Context::class.java)
        val preferences = mock(CaptioningManager::class.java)
        `when`(context.getSystemService(Context.CAPTIONING_SERVICE)).thenReturn(preferences)
        `when`(preferences.isEnabled).thenReturn(true)
        `when`(preferences.fontScale).thenReturn(2f)
        fun field(name: String, value: Any) {
            VideoPlayerView::class.java.getDeclaredField(name).apply {
                isAccessible = true
                set(view, value)
            }
        }
        field("session", session)
        field("context", context)
        field("pipControls", PipControlVisibility())
        if (lightweight) {
            field("lightSubtitleView", captions)
        } else {
            val playerView = mock(PlayerView::class.java)
            `when`(playerView.subtitleView).thenReturn(captions)
            field("playerView", playerView)
        }
        return view to captions
    }
}
