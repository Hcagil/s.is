package com.esd.sis

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

private const val MAX_SHARED = 10
private const val SHARED_IMAGE_EDGE = 1600
// The largest video source a share may copy (a 5 minute video is far below this).
private const val MAX_VIDEO_BYTES = 1L shl 30
// The message length limit of the app (lib/features/chat/domain/message.dart maxMessageLength).
private const val MAX_TEXT_CHARS = 4000

// Copies what another app shared (ACTION_SEND / SEND_MULTIPLE) into our cache so
// Dart can read it as plain files. Only content:// URIs of OTHER apps are
// accepted: otherwise a hostile app could make SIS copy (and send) its own
// private files.
class ShareIntakeReader(private val context: Context) {
    fun isShare(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_SEND || intent?.action == Intent.ACTION_SEND_MULTIPLE

    // Blocking file I/O: call off the main thread.
    fun read(intent: Intent): Map<String, Any?>? {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }?.take(MAX_TEXT_CHARS)?.let { if (it.last().isHighSurrogate()) it.dropLast(1) else it }

        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let { uris.addAll(it) }
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            }
        } else if (intent.action == Intent.ACTION_SEND) {
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let { uris.add(it) }
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
            }
        }

        val accepted = uris.filter { uri -> isOtherAppsContent(uri) }.take(MAX_SHARED)

        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val items = mutableListOf<Map<String, Any?>>()

        accepted.forEachIndexed { index, uri ->
            val type = context.contentResolver.getType(uri) ?: ""
            val isVideo = type.startsWith("video/")
            if (!isVideo && !type.startsWith("image/")) return@forEachIndexed

            val name = context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null } ?: "shared"

            if (!isVideo) {
                try {
                    val processed = File(PickedImageProcessor(context).process(uri, SHARED_IMAGE_EDGE))
                    // Moved into the share folder so cleanStale sweeps it; only this path put it there.
                    val kept = File(dir, "share-${System.nanoTime()}-$index.jpg")
                    val path = if (processed.renameTo(kept)) kept.absolutePath else processed.absolutePath
                    items.add(mapOf("path" to path, "name" to name, "video" to false))
                } catch (e: Exception) {
                    // Unreadable or not a photo: left out of the share.
                }
                return@forEachIndexed
            }

            val file = File(dir, "share-${System.nanoTime()}-$index.mp4")
            try {
                val input = context.contentResolver.openInputStream(uri) ?: return@forEachIndexed
                val whole = input.use { i -> copyCapped(i, file) }
                if (!whole) {
                    file.delete()
                    return@forEachIndexed
                }
                items.add(mapOf("path" to file.absolutePath, "name" to name, "video" to isVideo))
            } catch (e: Exception) {
                file.delete()
            }
        }

        return if (text == null && items.isEmpty()) null else mapOf("text" to text, "items" to items)
    }

    // The authority is user input: "0@com.esd.sis.x" would pass a plain prefix check and the
    // ContentResolver strips the "0@" again. So an '@' is refused and the real owner of the
    // provider is looked up; ours is refused.
    private fun isOtherAppsContent(uri: Uri): Boolean {
        val authority = uri.authority ?: return false
        if (uri.scheme != "content" || authority.contains('@')) return false
        if (authority.startsWith(context.packageName)) return false
        // A provider this app cannot see is another app's (ours is always visible); one that does not exist cannot be opened.
        return context.packageManager.resolveContentProvider(authority, 0)?.packageName != context.packageName
    }

    // Copies at most MAX_VIDEO_BYTES; false (the partial file is the caller's to delete) when the source is bigger.
    private fun copyCapped(input: InputStream, file: File): Boolean {
        FileOutputStream(file).use { out ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val n = input.read(buffer)
                if (n < 0) return true
                total += n
                if (total > MAX_VIDEO_BYTES) return false
                out.write(buffer, 0, n)
            }
        }
    }

    // Shares the app never picked up (killed before sending) must not pile up.
    fun cleanStale() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        File(context.cacheDir, "shared").listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
        // The raw copy PickedImageProcessor leaves when the app is killed mid-copy; a day old is never in use.
        context.cacheDir.listFiles()?.forEach { if (it.name.startsWith("picked_raw_") && it.lastModified() < cutoff) it.delete() }
    }
}
