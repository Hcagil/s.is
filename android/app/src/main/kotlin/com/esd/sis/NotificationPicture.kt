package com.esd.sis

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/** The small picture a chat notification shows for a photo or video message: where it is kept, who may read it, when it goes. */
object NotificationPicture {
    private const val DIR = "notif"
    private const val AUTHORITY_SUFFIX = ".captures" // the FileProvider in AndroidManifest.xml
    private const val SYSTEM_UI = "com.android.systemui"
    private const val STALE_MS = 60L * 60 * 1000

    /** The cache file for [name], or null when [name] is not a plain "<message id>.jpg" (nothing outside the folder is ever touched). */
    fun file(context: Context, name: String): File? {
        if (!name.matches(Regex("^[0-9a-fA-F-]{36}\\.jpg$"))) return null
        return File(File(context.cacheDir, DIR), name)
    }

    /** A content:// URI for the picture [name] that the system UI (which draws the shade) may read, or null when the file is gone or the name is not valid. Grants com.android.systemui read access to this one URI. */
    fun uri(context: Context, name: String): Uri? {
        val f = file(context, name) ?: return null
        if (!f.exists()) return null
        return try {
            val u = FileProvider.getUriForFile(context, context.packageName + AUTHORITY_SUFFIX, f)
            context.grantUriPermission(SYSTEM_UI, u, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            u
        } catch (e: Exception) {
            null
        }
    }

    /** [source] with a round dark badge and a white play triangle in the middle, drawn on a copy (the video's poster). */
    fun withPlayMark(source: android.graphics.Bitmap): android.graphics.Bitmap {
        val out = source.copy(android.graphics.Bitmap.Config.ARGB_8888, true)
        val canvas = android.graphics.Canvas(out)
        val cx = out.width / 2f
        val cy = out.height / 2f
        val r = minOf(out.width, out.height) * 0.14f
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        paint.color = android.graphics.Color.argb(150, 0, 0, 0)
        canvas.drawCircle(cx, cy, r, paint)
        paint.color = android.graphics.Color.WHITE
        val triangle = android.graphics.Path()
        triangle.moveTo(cx - r * 0.3f, cy - r * 0.5f)
        triangle.lineTo(cx - r * 0.3f, cy + r * 0.5f)
        triangle.lineTo(cx + r * 0.55f, cy)
        triangle.close()
        canvas.drawPath(triangle, paint)
        return out
    }

    /** Downloads the small picture at the https link [url] (the signed link the push carried: never logged), draws a play mark on a video's poster, and stores it as "<messageId>.jpg" in the notification picture folder. Returns the file name, or null on any problem (offline, expired link, not a picture, bigger than 256 KiB, slower than 4 s per step). Blocks: call it off the main thread. */
    fun fetch(context: Context, url: String, video: Boolean, messageId: String): String? {
        if (!url.startsWith("https://")) return null
        val name = "$messageId.jpg"
        val target = file(context, name) ?: return null
        var connection: java.net.HttpURLConnection? = null
        return try {
            connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 4000
            connection.readTimeout = 4000
            connection.instanceFollowRedirects = false
            if (connection.responseCode != 200) return null
            val limit = 256 * 1024
            val bytes = java.io.ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    bytes.write(buffer, 0, n)
                    if (bytes.size() > limit) return null
                }
            }
            val raw = bytes.toByteArray()
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(raw, 0, raw.size, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
            val shown = if (video) withPlayMark(bitmap) else bitmap
            target.parentFile?.mkdirs()
            java.io.FileOutputStream(target).use { shown.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, it) }
            name
        } catch (e: Throwable) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    /** Deletes pictures that no stored line [keep]s and that are older than an hour. Never throws. */
    fun prune(context: Context, keep: Set<String>) {
        try {
            File(context.cacheDir, DIR).listFiles()?.forEach {
                if (it.name !in keep && System.currentTimeMillis() - it.lastModified() > STALE_MS) it.delete()
            }
        } catch (e: Exception) {
        }
    }
}
