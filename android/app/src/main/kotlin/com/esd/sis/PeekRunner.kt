package com.esd.sis

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.annotation.VisibleForTesting
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** For an encrypted push that carries ciphertext, ask Dart (a short-lived headless Flutter engine) for the message text. The text comes back in memory; Dart may also save it into the phone store (push_inbox) before it answers 'done', so the engine is never destroyed before 'done' while the push time lasts (plus a short grace). */
object PeekRunner {
    private const val CHANNEL = "com.esd.sis/peek"
    private const val ENTRY_LIBRARY = "package:sis/features/notifications/data/push_peek_entry.dart"
    // One burst of pushes shares BURST_BUDGET_MS (the receiver's goAsync limit is ~10 s and pushes are drawn one after another); one push waits at most PUSH_CAP_MS; a spent budget draws locked. The budget starts again after a quiet gap.
    private const val PUSH_CAP_MS = 3000L
    private const val BURST_BUDGET_MS = 6000L
    private const val QUIET_GAP_MS = 15000L
    // Extra wait after the push cap, so an engine that is in the middle of its store write (committing, closing) is not destroyed under it.
    private const val WRITE_GRACE_MS = 300L
    private var burstSpentMs = 0L
    private var lastPeekEnd = 0L

    /** Test seam: when set, replaces the engine (unit tests cannot start Flutter). */
    @Volatile var override: ((Bundle) -> String?)? = null

    // Reason codes by message_id, so two overlapping pushes never read each other's; each is taken once by the receiver.
    private val reasons = java.util.concurrent.ConcurrentHashMap<String, String>()

    // Peer names by message_id, like [reasons].
    private val names = java.util.concurrent.ConcurrentHashMap<String, String>()

    /** The chat partner's name from this phone's own copy of the chat, read once after peek() of the push with that message id; null when the phone has no copy or no peek ran. */
    fun takeName(messageId: String): String? = names.remove(messageId)

    /** The reason code of the peek() of the push with [messageId], read once by the receiver; null when no peek was attempted for it. */
    fun takeReason(messageId: String): String? = reasons.remove(messageId)

    private fun fail(messageId: String?, code: String): String? { if (messageId != null) reasons[messageId] = code; return null }

    /** Test seam: the clock for every budget time read. */
    @VisibleForTesting @Volatile var now: () -> Long = { System.currentTimeMillis() }

    /** Test seam: called after the budget check instead of starting a real engine; gets the ms this push may still use. Its elapsed time (via [now]) is charged to the budget like a real peek. */
    @VisibleForTesting @Volatile var engine: ((Bundle, Long) -> String?)? = null

    /** Test seam: forgets the burst budget. */
    @VisibleForTesting fun resetBudget() = synchronized(this) {
        burstSpentMs = 0L
        lastPeekEnd = 0L
    }

    /** True when [extras] is an encrypted push with ciphertext: encrypted == "true", non-empty "ct", "ot" is "0" or "1", and non-empty user_id, conversation_id, message_id. */
    fun wanted(extras: Bundle): Boolean =
        extras.getString("encrypted") == "true" &&
            !extras.getString("ct").isNullOrEmpty() &&
            extras.getString("ot").let { it == "0" || it == "1" } &&
            !extras.getString("user_id").isNullOrEmpty() &&
            !extras.getString("conversation_id").isNullOrEmpty() &&
            !extras.getString("message_id").isNullOrEmpty()

    /** The message text, or null (= stay locked) on any failure, timeout, or when called on the main thread. Blocks the caller up to TIMEOUT_MS; call it from the draw thread only. */
    fun peek(context: Context, extras: Bundle): String? {
        val mid = extras.getString("message_id")
        mid?.let { reasons.remove(it) }
        mid?.let { names.remove(it) }
        if (!wanted(extras)) return fail(mid, "not_wanted")
        override?.let { return it(extras) }
        if (Looper.myLooper() == Looper.getMainLooper()) return fail(mid, "main_thread")
        val timeout = synchronized(this) {
            if (now() - lastPeekEnd > QUIET_GAP_MS) burstSpentMs = 0L
            minOf(PUSH_CAP_MS, BURST_BUDGET_MS - burstSpentMs)
        }
        if (timeout < 500L) return fail(mid, "budget")
        val startedAt = now()
        engine?.let { fake ->
            val text = try { fake(extras, timeout) } finally { charge(startedAt) }
            val seamText = text?.takeIf { it.isNotEmpty() } ?: return fail(mid, "other:seam")
            mid?.let { reasons[it] = "ok" }
            return seamText
        }

        // sk/si (a pre-key push's sender key and id) ride along only when present: the Dart side casts this map to Map<String, String>. Never logged.
        val args = (listOf("user_id", "conversation_id", "message_id", "ct", "ot") + listOf("sk", "si").filter { !extras.getString(it).isNullOrEmpty() }).associateWith { extras.getString(it)!! }
        val latch = CountDownLatch(1)
        val result = AtomicReference<String?>(null)
        val dartReason = AtomicReference<String?>(null)
        val dartName = AtomicReference<String?>(null)
        val engineRef = AtomicReference<FlutterEngine?>(null)
        val main = Handler(Looper.getMainLooper())

        main.post {
            try {
                val app = context.applicationContext
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
                // false: do not register every plugin of the app; only the three below.
                val flutter = FlutterEngine(app, null, false)
                engineRef.set(flutter)
                // Only what peekMain uses: the key storage and the JNI plugins that path_provider's Android code runs on.
                flutter.plugins.add(com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin())
                flutter.plugins.add(com.github.dart_lang.jni.JniPlugin())
                flutter.plugins.add(com.github.dart_lang.jni_flutter.JniFlutterPlugin())
                MethodChannel(flutter.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, res ->
                    when (call.method) {
                        // budget_ms: the push time Dart may still use; it saves the text into the store only with at least 500 ms left.
                        "take" -> res.success(args + ("budget_ms" to (timeout - (now() - startedAt)).coerceAtLeast(0L).toString()))
                        "done" -> {
                            val m = call.arguments as? Map<*, *>
                            result.set(m?.get("text") as? String)
                            dartReason.set(m?.get("reason") as? String)
                            dartName.set(m?.get("name") as? String)
                            res.success(null)
                            latch.countDown()
                        }
                        else -> res.notImplemented()
                    }
                }
                flutter.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRY_LIBRARY, "peekMain"),
                )
            } catch (t: Throwable) {
                android.util.Log.w("PeekRunner", "engine failed: ${t.javaClass.simpleName}")
                dartReason.set("other:" + t.javaClass.simpleName.take(40).replace(Regex("[^A-Za-z0-9_]"), "_"))
                latch.countDown()
            }
        }

        val finished = latch.await(timeout, TimeUnit.MILLISECONDS) || latch.await(WRITE_GRACE_MS, TimeUnit.MILLISECONDS)
        main.post { engineRef.get()?.destroy() }
        charge(startedAt)
        if (!finished) return fail(mid, "timeout")
        val text = result.get()?.takeIf { it.isNotEmpty() }
        val r = dartReason.get()
        mid?.let { m -> dartName.get()?.takeIf { it.isNotEmpty() }?.take(200)?.let { names[m] = it } }
        mid?.let {
            reasons[it] = when {
                text != null -> "ok"
                r != null && r.matches(Regex("^[a-z_]{1,24}(:[A-Za-z0-9_]{1,40})?$")) -> r
                else -> "other:unknown"
            }
        }
        return text
    }

    private fun charge(startedAt: Long) = synchronized(this) {
        lastPeekEnd = now()
        burstSpentMs += lastPeekEnd - startedAt
    }
}
