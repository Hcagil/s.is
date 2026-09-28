package com.esd.sis

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val CHANNEL = "sis/external_picker"
private const val REQUEST_ATTACHMENTS = 9101
private const val REQUEST_PICTURE = 9102
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

    // PickedImageProcessor.process() does file I/O, bitmap decode/rotate/
    // scale and JPEG compression for up to 10 photos; on the main thread
    // that risks freezing the UI or an ANR.
    private val pickExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        pickExecutor.shutdown()
        super.onDestroy()
    }

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
        pickExecutor.execute {
            val processor = PickedImageProcessor(this@MainActivity)
            val paths = mutableListOf<String>()
            try {
                for (uri in uris) paths.add(processor.process(uri, square))
                runOnUiThread {
                    if (square) {
                        result.success(paths)
                    } else {
                        result.success(mapOf("paths" to paths, "dropped" to dropped))
                    }
                }
            } catch (e: NotImageException) {
                // Delete whatever was already produced before the failure --
                // an orphaned output file otherwise leaks in the cache dir.
                paths.forEach { File(it).delete() }
                runOnUiThread { result.error("not_image", "Not a photo.", null) }
            } catch (e: Exception) {
                paths.forEach { File(it).delete() }
                runOnUiThread { result.error("unreadable", "Could not read the photo.", null) }
            }
        }
    }
}
