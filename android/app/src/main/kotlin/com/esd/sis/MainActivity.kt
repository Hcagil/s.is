package com.esd.sis

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.speech.SpeechRecognizer
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private const val CHANNEL = "sis/external_picker"
private const val TONE_CHANNEL = "sis/tone_picker"
private const val NETWORK_CHANNEL = "sis/network"
private const val SPEECH_CHANNEL = "sis/speech"
private const val SHARE_CHANNEL = "sis/share_intake"
private const val REPLY_CHANNEL = "sis/encrypted_reply"
private const val LAUNCH_TAP_CHANNEL = "sis/launch_tap"
private const val REQUEST_TONE = 9103
private const val REQUEST_ATTACHMENTS = 9101
private const val REQUEST_PICTURE = 9102
private const val REQUEST_CAMERA = 9104
private const val MAX_ATTACHMENTS = 10
private const val ATTACHMENT_EDGE = 1600
private const val PICTURE_EDGE = 2048

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
    private var pendingTone: MethodChannel.Result? = null
    private var cameraFile: File? = null

    // PickedImageProcessor.process() does file I/O, bitmap decode/rotate/
    // scale and JPEG compression for up to 10 photos; on the main thread
    // that risks freezing the UI or an ANR.
    private val pickExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val stickerCutout by lazy { StickerCutout(this) }
    private val shareReader by lazy { ShareIntakeReader(this) }
    private var shareChannel: MethodChannel? = null
    private var replyChannel: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private var shareParsing = false
    private val shareWaiters = mutableListOf<MethodChannel.Result>()

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Before super: the Flutter plugins read the launch intent from there. A tap without our proof is dropped.
        TapProof.admit(this, intent)
        super.onCreate(savedInstanceState)
    }

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
                    "takePhoto" -> takePhoto(result)
                    "cropPicture" -> cropPicture(call, result)
                    "cutoutSupported" -> result.success(stickerCutout.supported().also { if (it) stickerCutout.requestModel() })
                    "cutoutMask" -> cutoutMask(call, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TONE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "pick") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                pickTone((call.arguments as? Map<*, *>)?.get("current") as? String, result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NETWORK_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "isRoaming") result.success(isRoaming()) else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "onDeviceAvailable") result.success(onDeviceSpeechAvailable()) else result.notImplemented()
            }
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).also {
            it.setMethodCallHandler { call, result -> if (call.method == "take") takeShare(result) else result.notImplemented() }
        }
        // Replies typed into a private-chat notification (EncryptedReplyActivity): Dart takes them and sends them through the encrypted send queue. Memory only.
        replyChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REPLY_CHANNEL).also {
            it.setMethodCallHandler { call, result -> if (call.method == "take") result.success(EncryptedReplyInbox.take()) else result.notImplemented() }
        }
        // A cold start from a notification tap: Dart reads the chat id at once, without waiting for Firebase. Taken once (the action is cleared) so a recreate or a launch from history does not reopen the chat.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LAUNCH_TAP_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "take") result.success(takeLaunchTap()) else result.notImplemented()
            }
        shareReader.cleanStale()
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        TapProof.admit(this, intent)
        super.onNewIntent(intent)
        setIntent(intent)
        handleShare(intent)
        replyChannel?.invokeMethod("arrived", null) // a Reply may have been left in EncryptedReplyInbox just before this launch
    }

    private fun takeLaunchTap(): String? {
        val launch = intent ?: return null
        if (launch.action != "SELECT_NOTIFICATION") return null
        if ((launch.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
        val payload = launch.getStringExtra("payload")
        launch.action = null
        return payload?.takeIf { it.isNotEmpty() }
    }

    // Dart asks for the share that started or reached the app. A parse still
    // running is waited for; nothing waiting answers null. A share is handed
    // over once: it is cleared as it is taken.
    private fun takeShare(result: MethodChannel.Result) {
        val ready = pendingShare
        when {
            ready != null -> { pendingShare = null; result.success(ready) }
            shareParsing -> shareWaiters.add(result)
            else -> result.success(null)
        }
    }

    // Copies a share intent's files into the cache off the main thread, then
    // hands them to a waiting Dart ask or tells Dart they arrived. A launch from
    // history must not replay an old share.
    private fun handleShare(intent: Intent?) {
        if (intent == null || !shareReader.isShare(intent)) return
        if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        val copy = Intent(intent)
        intent.action = null // consumed: a recreate must not read it again
        shareParsing = true
        pickExecutor.execute {
            val parsed = try { shareReader.read(copy) } catch (e: Exception) { null }
            runOnUiThread {
                shareParsing = false
                if (parsed == null) {
                    shareWaiters.forEach { it.success(null) }
                } else if (shareWaiters.isNotEmpty()) {
                    shareWaiters.removeAt(0).success(parsed)
                    shareWaiters.forEach { it.success(null) }
                } else {
                    pendingShare = parsed
                    shareChannel?.invokeMethod("arrived", null)
                }
                shareWaiters.clear()
            }
        }
    }

    // True when the active network is cellular and the carrier marks it as
    // roaming (connectivity_plus cannot tell). Needs only ACCESS_NETWORK_STATE,
    // which the connectivity_plus plugin's manifest already declares.
    private fun isRoaming(): Boolean {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        val network = manager.activeNetwork ?: return false
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) &&
            !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING)
    }

    // True only when this phone can recognise speech WITHOUT a server (the
    // Android 12+ on-device recogniser). speech_to_text silently falls back to
    // the network recogniser otherwise, so Dart asks first (docs/DECISIONS.md,
    // voice messages).
    private fun onDeviceSpeechAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(this)

    // The phone's own notification-sound chooser. A null uri in the reply
    // means the system default; a null reply means the member cancelled.
    private fun pickTone(current: String?, result: MethodChannel.Result) {
        if (pendingTone != null) {
            result.error("busy", "A picker is already open.", null)
            return
        }
        pendingTone = result
        val defaultUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
            putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_NOTIFICATION)
            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
            putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
            putExtra(RingtoneManager.EXTRA_RINGTONE_DEFAULT_URI, defaultUri)
            putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, if (current != null) Uri.parse(current) else defaultUri)
        }
        try {
            startActivityForResult(intent, REQUEST_TONE)
        } catch (e: ActivityNotFoundException) {
            pendingTone = null
            result.error("no_app", "No app can open ringtones.", null)
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

    // The camera app, through the camera intent: it needs no CAMERA
    // permission of ours. It writes the photo into a file of ours (shared
    // through FileProvider, see AndroidManifest.xml), which is processed like
    // any picked photo and then deleted.
    private fun takePhoto(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "A picker is already open.", null)
            return
        }
        val dir = File(cacheDir, "captures").apply { mkdirs() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
        val uri = FileProvider.getUriForFile(this, "$packageName.captures", file)
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingResult = result
        cameraFile = file
        try {
            startActivityForResult(intent, REQUEST_CAMERA)
        } catch (e: ActivityNotFoundException) {
            pendingResult = null
            cameraFile = null
            file.delete()
            result.error("no_camera", "No camera on this device.", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_TONE) {
            val result = pendingTone
            pendingTone = null
            if (result == null) return
            val uri = if (resultCode != Activity.RESULT_OK || data == null) {
                null
            } else if (Build.VERSION.SDK_INT >= 33) {
                data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                data.getParcelableExtra<Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            }
            when {
                uri == null -> result.success(null)
                uri == RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION) ->
                    result.success(mapOf("uri" to null, "name" to "System default"))
                else -> result.success(
                    mapOf("uri" to uri.toString(), "name" to (RingtoneManager.getRingtone(this, uri)?.getTitle(this) ?: "Custom")),
                )
            }
            return
        }
        if (requestCode == REQUEST_CAMERA) {
            val result = pendingResult
            pendingResult = null
            val file = cameraFile
            cameraFile = null
            if (result == null) {
                file?.delete()
                return
            }
            if (resultCode != Activity.RESULT_OK || file == null || !file.exists() || file.length() == 0L) {
                file?.delete()
                result.success(null)
                return
            }
            pickExecutor.execute {
                try {
                    val path = PickedImageProcessor(this@MainActivity).process(Uri.fromFile(file), ATTACHMENT_EDGE)
                    runOnUiThread { result.success(mapOf("paths" to listOf(path), "dropped" to 0)) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("unreadable", "Could not read the photo.", null) }
                } finally {
                    file.delete()
                }
            }
            return
        }
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
        val isPicture = requestCode == REQUEST_PICTURE
        // Capped before anything is opened: the extras' bytes are never
        // read, so there is nothing of theirs to delete.
        val dropped = if (isPicture) 0 else maxOf(0, allUris.size - MAX_ATTACHMENTS)
        val uris = if (isPicture) allUris else allUris.take(MAX_ATTACHMENTS)
        pickExecutor.execute {
            val processor = PickedImageProcessor(this@MainActivity)
            val paths = mutableListOf<String>()
            try {
                for (uri in uris) paths.add(processor.process(uri, if (isPicture) PICTURE_EDGE else ATTACHMENT_EDGE))
                runOnUiThread {
                    if (isPicture) {
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

    // Crops a picture-source file into a picture, off the main thread; not
    // part of the pick/onActivityResult flow above, so it never touches
    // pendingResult.
    private fun cropPicture(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val path = args?.get("path") as? String
        val left = (args?.get("left") as? Number)?.toDouble()
        val top = (args?.get("top") as? Number)?.toDouble()
        val right = (args?.get("right") as? Number)?.toDouble()
        val bottom = (args?.get("bottom") as? Number)?.toDouble()
        val size = (args?.get("size") as? Number)?.toInt() ?: 640
        val quality = (args?.get("quality") as? Number)?.toInt() ?: 82
        if (path == null || left == null || top == null || right == null || bottom == null) {
            result.error("bad_args", "Missing crop arguments.", null)
            return
        }
        pickExecutor.execute {
            try {
                val output = PickedImageProcessor(this@MainActivity).crop(path, left, top, right, bottom, size, quality)
                runOnUiThread { result.success(output) }
            } catch (e: Exception) {
                runOnUiThread { result.error("crop_failed", "Could not crop the photo.", null) }
            }
        }
    }

    // Background-removal mask for a sticker photo; ML Kit calls back on its own thread, so hop to the UI thread to reply. Null reply = no mask (the caller keeps the whole image).
    private fun cutoutMask(call: MethodCall, result: MethodChannel.Result) {
        val bytes = (call.arguments as? Map<*, *>)?.get("bytes") as? ByteArray
        if (bytes == null) { result.error("bad_args", "Missing photo bytes.", null); return }
        pickExecutor.execute { stickerCutout.mask(bytes) { mask -> runOnUiThread { result.success(mask) } } }
    }
}
