package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenter
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import kotlin.math.roundToInt

private const val SIDE = 512

// Background removal for a sticker photo with ML Kit subject segmentation. The
// model is unbundled: Google Play services downloads it, and a request made
// before the download finishes fails -- the caller then keeps the whole image.
class StickerCutout(private val context: Context) {
    // False on a phone without Google Play services (no model can be had).
    fun supported(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

    // [onDone] gets 512*512 foreground-confidence bytes (0..255, row-major), or
    // null on any failure or when no subject was found. Called exactly once.
    fun mask(jpeg: ByteArray, onDone: (ByteArray?) -> Unit) {
        var scaled: Bitmap? = null
        var segmenter: SubjectSegmenter? = null
        try {
            val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            if (decoded == null) {
                onDone(null)
                return
            }
            val small = Bitmap.createScaledBitmap(decoded, SIDE, SIDE, true)
            scaled = small
            // createScaledBitmap hands back the same object when no scaling is needed.
            if (small !== decoded) decoded.recycle()
            val seg = SubjectSegmentation.getClient(
                SubjectSegmenterOptions.Builder().enableForegroundConfidenceMask().build()
            )
            segmenter = seg
            fun finish(bytes: ByteArray?) {
                seg.close()
                small.recycle()
                onDone(bytes)
            }
            seg.process(InputImage.fromBitmap(small, 0))
                .addOnSuccessListener { result ->
                    val mask = result.foregroundConfidenceMask
                    if (mask == null) {
                        finish(null)
                        return@addOnSuccessListener
                    }
                    mask.rewind()
                    val floats = FloatArray(SIDE * SIDE)
                    if (mask.remaining() < floats.size) {
                        finish(null)
                        return@addOnSuccessListener
                    }
                    mask.get(floats)
                    val bytes = ByteArray(floats.size) { (floats[it] * 255).roundToInt().coerceIn(0, 255).toByte() }
                    finish(if (floats.any { it > 0.1f }) bytes else null)
                }
                .addOnFailureListener { finish(null) }
        } catch (e: Throwable) {
            // An OutOfMemoryError is not an Exception; the channel must still answer.
            segmenter?.close()
            scaled?.recycle()
            onDone(null)
        }
    }
}
