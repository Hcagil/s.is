package com.esd.sis
import kotlin.math.roundToInt

/**
 * U-2-Net model math.
 */
object U2NetMath {
    /**
     * Model input side in pixels.
     */
    const val MODEL_SIDE = 320

    /**
     * Mask output side in pixels.
     */
    const val MASK_SIDE = 512

    /**
     * Converts ARGB pixel data to normalized float tensor.
     *
     * @param argb input pixels, size MODEL_SIDE*MODEL_SIDE
     * @return float tensor in CHW order, size 3*MODEL_SIDE*MODEL_SIDE
     */
    fun input(argb: IntArray): FloatArray {
        require(argb.size == MODEL_SIDE * MODEL_SIDE)
        val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
        val std = floatArrayOf(0.229f, 0.224f, 0.225f)
        val result = FloatArray(3 * MODEL_SIDE * MODEL_SIDE)
        for (i in argb.indices) {
            val p = argb[i]
            val r = (p shr 16) and 0xFF
            val g = (p shr 8) and 0xFF
            val b = p and 0xFF
            result[i] = (r / 255f - mean[0]) / std[0]
            result[MODEL_SIDE * MODEL_SIDE + i] = (g / 255f - mean[1]) / std[1]
            result[2 * MODEL_SIDE * MODEL_SIDE + i] = (b / 255f - mean[2]) / std[2]
        }
        return result
    }

    /**
     * Converts foreground probabilities to mask bytes.
     *
     * @param probs foreground probabilities, size MODEL_SIDE*MODEL_SIDE
     * @return mask bytes, size MASK_SIDE*MASK_SIDE, or null if not enough confidence
     */
    fun mask(probs: FloatArray): ByteArray? {
        if (probs.size != MODEL_SIDE * MODEL_SIDE) return null
        val min = probs.minOrNull() ?: 0f
        val max = probs.maxOrNull() ?: 0f
        if (max - min < 0.05f) return null
        val range = max - min
        val upscaled = FloatArray(MASK_SIDE * MASK_SIDE)
        for (y in 0 until MASK_SIDE) {
            for (x in 0 until MASK_SIDE) {
                val srcX = x * (MODEL_SIDE - 1).toFloat() / (MASK_SIDE - 1)
                val srcY = y * (MODEL_SIDE - 1).toFloat() / (MASK_SIDE - 1)
                val x0 = srcX.toInt()
                val x1 = minOf(x0 + 1, MODEL_SIDE - 1)
                val y0 = srcY.toInt()
                val y1 = minOf(y0 + 1, MODEL_SIDE - 1)
                val fx = srcX - x0
                val fy = srcY - y0
                val a = probs[y0 * MODEL_SIDE + x0]
                val b = probs[y0 * MODEL_SIDE + x1]
                val c = probs[y1 * MODEL_SIDE + x0]
                val d = probs[y1 * MODEL_SIDE + x1]
                val value = a * (1 - fx) * (1 - fy) +
                    b * fx * (1 - fy) +
                    c * (1 - fx) * fy +
                    d * fx * fy
                upscaled[y * MASK_SIDE + x] = (value - min) / range
            }
        }
        val bytes = ByteArray(MASK_SIDE * MASK_SIDE)
        for (i in upscaled.indices) {
            val byte = (upscaled[i] * 255f).roundToInt().coerceIn(0, 255).toByte()
            bytes[i] = byte
        }
        return if (bytes.any { (it.toInt() and 0xFF) > 25 }) bytes else null
    }
}
