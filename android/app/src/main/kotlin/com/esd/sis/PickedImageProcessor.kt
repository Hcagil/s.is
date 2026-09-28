package com.esd.sis

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

private const val JPEG_QUALITY = 85

class NotImageException : Exception()

// One instance per pick. Copies a picked photo's bytes into the cache dir,
// decodes, EXIF-rotates and resizes/crops it, and writes the result back as
// a JPEG -- the file I/O and bitmap work MainActivity keeps off the main
// thread.
class PickedImageProcessor(private val context: Context) {
    // Copies [uri]'s bytes into the cache dir right away (its read grant is
    // temporary), then decodes, EXIF-rotates and resizes/crops it, and
    // writes the result as a JPEG back into the cache dir. Returns the
    // final file's absolute path.
    fun process(uri: Uri, maxEdge: Int): String {
        val resolver = context.contentResolver
        val type = resolver.getType(uri)
        if (type != null && !type.startsWith("image/")) throw NotImageException()
        val raw = File(context.cacheDir, "picked_raw_${System.nanoTime()}")
        val input = resolver.openInputStream(uri) ?: throw NotImageException()
        input.use { stream ->
            FileOutputStream(raw).use { output -> stream.copyTo(output) }
        }
        try {
            val orientation = try {
                ExifInterface(raw.absolutePath)
                    .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            } catch (e: Exception) {
                ExifInterface.ORIENTATION_NORMAL
            }
            var bitmap = decodeSampledBitmap(raw.absolutePath, maxEdge) ?: throw NotImageException()
            bitmap = applyExifOrientation(bitmap, orientation)
            bitmap = scaleLongEdge(bitmap, maxEdge)
            val out = File(context.cacheDir, "picked_${System.nanoTime()}.jpg")
            FileOutputStream(out).use { fos -> bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, fos) }
            bitmap.recycle()
            return out.absolutePath
        } finally {
            raw.delete()
        }
    }

    // Decodes [path] downsampled so its dimensions are close to but not
    // under [target] in both axes, instead of decoding at full resolution
    // first -- a 50 MP photo decoded at full size is roughly 200 MB as an
    // ARGB_8888 bitmap.
    private fun decodeSampledBitmap(path: String, target: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = calcInSampleSize(bounds.outWidth, bounds.outHeight, target, target)
        }
        return BitmapFactory.decodeFile(path, options)
    }

    private fun calcInSampleSize(width: Int, height: Int, reqWidth: Int, reqHeight: Int): Int {
        var inSampleSize = 1
        if (height > reqHeight || width > reqWidth) {
            val halfHeight = height / 2
            val halfWidth = width / 2
            while ((halfHeight / inSampleSize) >= reqHeight && (halfWidth / inSampleSize) >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun applyExifOrientation(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return bitmap
        }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    private fun scaleLongEdge(bitmap: Bitmap, maxEdge: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val long = maxOf(w, h)
        if (long <= maxEdge) return bitmap
        val scale = maxEdge.toFloat() / long
        val scaled = Bitmap.createScaledBitmap(bitmap, (w * scale).roundToInt(), (h * scale).roundToInt(), true)
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }

    // Crops the JPEG at [sourcePath] (already an upright, decoded, long-edge
    // capped photo -- no EXIF to re-apply, produced by process() above) to
    // the rectangle given by fractions of its width/height, then scales
    // that square to [outputSize] and writes it as a JPEG at [quality].
    // Returns the new file's absolute path. Does not delete [sourcePath] --
    // the caller owns that file, same as MainActivity does for process()'s
    // output.
    fun crop(
        sourcePath: String,
        left: Double,
        top: Double,
        right: Double,
        bottom: Double,
        outputSize: Int,
        quality: Int,
    ): String {
        val bitmap = BitmapFactory.decodeFile(sourcePath) ?: throw NotImageException()
        try {
            val w = bitmap.width
            val h = bitmap.height
            val x = (left * w).roundToInt().coerceIn(0, w - 1)
            val y = (top * h).roundToInt().coerceIn(0, h - 1)
            val cropW = ((right - left) * w).roundToInt().coerceIn(1, w - x)
            val cropH = ((bottom - top) * h).roundToInt().coerceIn(1, h - y)
            val cropped = Bitmap.createBitmap(bitmap, x, y, cropW, cropH)
            val scaled = if (cropW == outputSize && cropH == outputSize) {
                cropped
            } else {
                Bitmap.createScaledBitmap(cropped, outputSize, outputSize, true)
            }
            if (scaled !== cropped) cropped.recycle()
            val out = File(context.cacheDir, "cropped_${System.nanoTime()}.jpg")
            FileOutputStream(out).use { fos -> scaled.compress(Bitmap.CompressFormat.JPEG, quality, fos) }
            scaled.recycle()
            return out.absolutePath
        } finally {
            bitmap.recycle()
        }
    }
}
