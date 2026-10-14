package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import io.flutter.FlutterInjector
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

// Runs the bundled U2-NetP with LiteRT: the fallback for phones without Google Play services.
class LiteRtCutout(private val context: Context) {
    @Volatile
    private var interpreter: Interpreter? = null

    // Synchronous and slow (about a second): call off the main thread. [bitmap] any size. Returns 512*512 mask bytes or null; never throws.
    fun mask(bitmap: Bitmap): ByteArray? {
        try {
            val s = open()
            val scaled = Bitmap.createScaledBitmap(bitmap, 320, 320, true)
            val pixels = IntArray(320 * 320)
            scaled.getPixels(pixels, 0, 320, 0, 0, 320, 320)
            if (scaled !== bitmap) scaled.recycle()
            val input = U2NetMath.input(pixels)
            val inputBuffer = ByteBuffer.allocateDirect(input.size * 4).order(ByteOrder.nativeOrder())
            inputBuffer.asFloatBuffer().put(input)
            val outputBuffer = ByteBuffer.allocateDirect(320 * 320 * 4).order(ByteOrder.nativeOrder())
            s.run(inputBuffer, outputBuffer)
            outputBuffer.rewind()
            val probs = FloatArray(320 * 320)
            outputBuffer.asFloatBuffer().get(probs)
            return U2NetMath.mask(probs)
        } catch (e: Throwable) {
            // OutOfMemoryError must not escape.
            return null
        }
    }

    private fun open(): Interpreter = interpreter ?: synchronized(this) { interpreter ?: createInterpreter().also { interpreter = it } }

    private fun createInterpreter(): Interpreter {
        val modelBytes = context.assets.open(FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/models/u2netp.tflite")).use { it.readBytes() }
        val buffer = ByteBuffer.allocateDirect(modelBytes.size).order(ByteOrder.nativeOrder())
        buffer.put(modelBytes)
        buffer.rewind()
        return Interpreter(buffer)
    }
}
