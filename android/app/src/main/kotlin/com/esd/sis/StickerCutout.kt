package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
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
    // Fallback to the bundled model when Google Play services is not available.
    private val onnx by lazy { OnnxCutout(context) }
    private val fallbackExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    // Always true: without Google Play services the bundled model is used.
    fun supported(): Boolean = true

    private fun playServices(): Boolean =
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS

    // Asks Google Play services to install the segmentation model now, so it is
    // (nearly) ready by the time mask() runs. Fire and forget: errors are ignored,
    // the Dart timeout handles a model that never arrives.
    // API: ModuleInstallClient (developers.google.com/android/guides/module-install-apis);
    // SubjectSegmenter implements OptionalModuleApi.
    fun requestModel() {
        if (!playServices()) return
        try {
            val seg = SubjectSegmentation.getClient(
                SubjectSegmenterOptions.Builder().enableForegroundConfidenceMask().build()
            )
            ModuleInstall.getClient(context)
                .installModules(ModuleInstallRequest.newBuilder().addApi(seg).build())
                .addOnCompleteListener { seg.close() }
        } catch (e: Throwable) {
            // Best effort only.
        }
    }

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
            if (!playServices()) {
                val out = onnx.mask(small)
                small.recycle()
                onDone(out)
                return
            }
            val seg = SubjectSegmentation.getClient(
                SubjectSegmenterOptions.Builder().enableForegroundConfidenceMask().build()
            )
            segmenter = seg
            fun finish(bytes: ByteArray?) {
                seg.close()
                if (bytes != null) {
                    small.recycle()
                    onDone(bytes)
                    return
                }
                // ML Kit calls back on the main thread; the model must not run there.
                fallbackExecutor.execute {
                    val out = onnx.mask(small)
                    small.recycle()
                    onDone(out)
                }
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
