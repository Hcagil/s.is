package com.esd.sis

import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** For an encrypted push that carries ciphertext, ask Dart (a short-lived headless Flutter engine) for the message text. Nothing is written anywhere: the text comes back in memory only. */
object PeekRunner {
    private const val CHANNEL = "com.esd.sis/peek"
    private const val ENTRY_LIBRARY = "package:sis/features/notifications/data/push_peek_entry.dart"
    private const val TIMEOUT_MS = 5000L

    /** Test seam: when set, replaces the engine (unit tests cannot start Flutter). */
    @Volatile var override: ((Bundle) -> String?)? = null

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
        override?.let { return it(extras) }
        if (!wanted(extras) || Looper.myLooper() == Looper.getMainLooper()) return null

        val args = listOf("user_id", "conversation_id", "message_id", "ct", "ot").associateWith { extras.getString(it) }
        val latch = CountDownLatch(1)
        val result = AtomicReference<String?>(null)
        val engineRef = AtomicReference<FlutterEngine?>(null)
        val main = Handler(Looper.getMainLooper())

        main.post {
            try {
                val app = context.applicationContext
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(app)
                loader.ensureInitializationComplete(app, null)
                val engine = FlutterEngine(app)
                engineRef.set(engine)
                GeneratedPluginRegistrant.registerWith(engine)
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, res ->
                    when (call.method) {
                        "take" -> res.success(args)
                        "done" -> {
                            result.set(call.arguments as? String)
                            res.success(null)
                            latch.countDown()
                        }
                        else -> res.notImplemented()
                    }
                }
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRY_LIBRARY, "peekMain"),
                )
            } catch (t: Throwable) {
                android.util.Log.w("PeekRunner", "engine failed: ${t.javaClass.simpleName}")
                latch.countDown()
            }
        }

        val finished = latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        main.post { engineRef.get()?.destroy() }
        return if (finished) result.get()?.takeIf { it.isNotEmpty() } else null
    }
}
