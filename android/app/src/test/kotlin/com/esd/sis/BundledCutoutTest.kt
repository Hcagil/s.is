package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.core.app.ApplicationProvider
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Bundled cut-out fallback on the JVM. Written from the contract, not the code:
 * - LiteRtCutout.mask never throws and returns null on any failure. Here the failure is real:
 *   LiteRT's native library is built for Android ABIs and cannot load on the JVM.
 * - StickerCutout.supported() is always true; mask() always answers its callback.
 * Which path StickerCutout takes (bundled vs ML Kit) is not observable here: the bundled model
 * cannot run on the JVM, so both paths end in null. That choice is checked on a device only.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BundledCutoutTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun photo(): Bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply {
        eraseColor(Color.WHITE)
        for (x in 16 until 48) for (y in 12 until 36) setPixel(x, y, Color.RED)
    }

    @Test
    fun `LiteRtCutout mask returns null instead of throwing when the runtime cannot run`() {
        val cutout = LiteRtCutout(context)
        assertNull(cutout.mask(photo()))
        // Second call goes through the cached (or re-tried) model and must also stay safe.
        assertNull(cutout.mask(photo()))
    }

    @Test
    fun `StickerCutout is always supported on Android`() {
        assertTrue(StickerCutout(context).supported())
    }

    @Test
    fun `StickerCutout mask answers with null and never throws when no path can cut out`() {
        val jpeg = ByteArrayOutputStream().also { photo().compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        val latch = CountDownLatch(1)
        val answers = mutableListOf<ByteArray?>()
        StickerCutout(context).mask(jpeg) { answers.add(it); latch.countDown() }
        val deadline = System.currentTimeMillis() + 10_000
        while (latch.count > 0 && System.currentTimeMillis() < deadline) {
            ShadowLooper.idleMainLooper()
            latch.await(50, TimeUnit.MILLISECONDS)
        }
        ShadowLooper.idleMainLooper()
        assertEquals(1, answers.size)
        assertNull(answers[0])
    }
}
