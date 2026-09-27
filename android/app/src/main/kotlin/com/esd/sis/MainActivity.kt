package com.esd.sis

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.math.roundToInt

private const val CHANNEL = "sis/external_picker"
private const val REQUEST_ATTACHMENTS = 9101
private const val REQUEST_PICTURE = 9102
private const val MAX_EDGE = 1600
private const val SQUARE_SIZE = 512
private const val JPEG_QUALITY = 85
private const val MAX_ATTACHMENTS = 10

// Android's own app chooser for "From an app" (docs/DECISIONS.md,
// 2026-09-28): ACTION_PICK on the images MediaStore URI, wrapped in
// Intent.createChooser so the system always shows an app list instead of
// routing to a single default handler or to Android's system photo picker
// (which only intercepts ACTION_GET_CONTENT for image/video mime types,
// not ACTION_PICK -- see developer.android.com/training/data-storage/shared/photopicker).
// Intent.createChooser is exempt from Android 11+ package-visibility
// filtering, so no <queries> manifest entry is needed.
class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickAttachments" -> startPick(multiple = true, requestCode = REQUEST_ATTACHMENTS, result = result)
                    "pickProfilePicture" -> startPick(multiple = false, requestCode = REQUEST_PICTURE, result = result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startPick(multiple: Boolean, requestCode: Int, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "A picker is already open.", null)
            return
        }
        pendingResult = result
        val pick = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
            type = "image/*"
            if (multiple) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(Intent.createChooser(pick, null), requestCode)
        } catch (e: ActivityNotFoundException) {
            pendingResult = null
            result.error("no_app", "No app can open photos.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_ATTACHMENTS && requestCode != REQUEST_PICTURE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingResult
        pendingResult = null
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }
        val allUris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) allUris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { allUris.add(it) }
        }
        if (allUris.isEmpty()) {
            result.success(null)
            return
        }
        val square = requestCode == REQUEST_PICTURE
        // Capped before anything is opened: the extras' bytes are never
        // read, so there is nothing of theirs to delete.
        val dropped = if (square) 0 else maxOf(0, allUris.size - MAX_ATTACHMENTS)
        val uris = if (square) allUris else allUris.take(MAX_ATTACHMENTS)
        try {
            val paths = uris.map { processImage(it, square) }
            if (square) result.success(paths) else result.success(mapOf("paths" to paths, "dropped" to dropped))
        } catch (e: NotImageException) {
            result.error("not_image", "Not a photo.", null)
        } catch (e: Exception) {
            result.error("unreadable", "Could not read the photo.", null)
        }
    }

    private class NotImageException : Exception()

    // Copies [uri]'s bytes into the cache dir right away (its read grant is
    // temporary), then decodes, EXIF-rotates and resizes/crops it, and
    // writes the result as a JPEG back into the cache dir. Returns the
    // final file's absolute path.
    private fun processImage(uri: Uri, square: Boolean): String {
        val resolver = contentResolver
        val type = resolver.getType(uri)
        if (type != null && !type.startsWith("image/")) throw NotImageException()
        val raw = File(cacheDir, "picked_raw_${System.nanoTime()}")
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
            var bitmap = BitmapFactory.decodeFile(raw.absolutePath) ?: throw NotImageException()
            bitmap = applyExifOrientation(bitmap, orientation)
            bitmap = if (square) centerCropSquare(bitmap, SQUARE_SIZE) else scaleLongEdge(bitmap, MAX_EDGE)
            val out = File(cacheDir, "picked_${System.nanoTime()}.jpg")
            FileOutputStream(out).use { fos -> bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, fos) }
            bitmap.recycle()
            return out.absolutePath
        } finally {
            raw.delete()
        }
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

    private fun centerCropSquare(bitmap: Bitmap, size: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val edge = minOf(w, h)
        val x = (w - edge) / 2
        val y = (h - edge) / 2
        val cropped = Bitmap.createBitmap(bitmap, x, y, edge, edge)
        if (cropped !== bitmap) bitmap.recycle()
        val scaled = if (edge == size) cropped else Bitmap.createScaledBitmap(cropped, size, size, true)
        if (scaled !== cropped) cropped.recycle()
        return scaled
    }
}
