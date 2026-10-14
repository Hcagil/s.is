package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import io.flutter.FlutterInjector
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer

class OnnxCutout(private val context: Context) {
    @Volatile
    private var session: OrtSession? = null
    private val env: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }

    // Synchronous and slow (about a second): call off the main thread. [bitmap] any size. Returns 512*512 mask bytes or null; never throws.
    fun mask(bitmap: Bitmap): ByteArray? {
        try {
            val s = open()
            val scaled = Bitmap.createScaledBitmap(bitmap, 320, 320, true)
            val pixels = IntArray(320 * 320)
            scaled.getPixels(pixels, 0, 320, 0, 0, 320, 320)
            if (scaled !== bitmap) scaled.recycle()
            val input = U2NetMath.input(pixels)
            val tensor = OnnxTensor.createTensor(env, FloatBuffer.wrap(input), longArrayOf(1, 3, 320, 320))
            try {
                val result = s.run(mapOf("input" to tensor))
                try {
                    val d0 = result.get("d0").get() as OnnxTensor
                    val probs = FloatArray(320 * 320)
                    d0.floatBuffer.get(probs)
                    return U2NetMath.mask(probs)
                } finally {
                    result.close()
                }
            } finally {
                tensor.close()
            }
        } catch (e: Throwable) {
            // OutOfMemoryError must not escape.
            return null
        }
    }

    private fun open(): OrtSession = session ?: synchronized(this) { session ?: createSession().also { session = it } }

    private fun createSession(): OrtSession {
        val modelBytes = context.assets.open(FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/models/u2netp.onnx")).use { it.readBytes() }
        return env.createSession(modelBytes, OrtSession.SessionOptions())
    }
}
