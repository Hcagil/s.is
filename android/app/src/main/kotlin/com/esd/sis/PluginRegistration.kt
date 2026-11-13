package com.esd.sis

import android.os.Handler
import android.os.Looper
import io.flutter.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener

/**
 * Registers the Flutter plugins in two groups instead of all 28 at once (cold start, docs/DECISIONS.md).
 * EARLY: what Dart can call before the chat list shows (storage, sign-in, push, links, update, network, app info).
 * LATE: plugins that Dart only calls after a user action (pickers, share, maps, media, voice); registered once,
 * on the main thread, right after Flutter has drawn its first frame. A plugin added to an attached engine gets
 * its activity callbacks at once, so a late plugin behaves like an early one.
 * Every plugin of GeneratedPluginRegistrant must be in exactly one of the two lists.
 */
object PluginRegistration {
    private const val TAG = "PluginRegistration"
    private val done = java.util.Collections.newSetFromMap(java.util.WeakHashMap<FlutterEngine, Boolean>())

    fun registerEarly(engine: FlutterEngine) {
        add(engine) { com.llfbandit.app_links.AppLinksPlugin() }
        add(engine) { dev.fluttercommunity.plus.connectivity.ConnectivityPlugin() }
        add(engine) { io.flutter.plugins.firebase.core.FlutterFirebaseCorePlugin() }
        add(engine) { io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingPlugin() }
        add(engine) { com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin() }
        add(engine) { io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin() }
        add(engine) { com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin() }
        add(engine) { io.flutter.plugins.googlesignin.GoogleSignInPlugin() }
        add(engine) { de.ffuf.in_app_update.InAppUpdatePlugin() }
        add(engine) { com.github.dart_lang.jni.JniPlugin() }
        add(engine) { com.github.dart_lang.jni_flutter.JniFlutterPlugin() }
        add(engine) { dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin() }
        add(engine) { io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin() }
        add(engine) { com.aboutyou.dart_packages.sign_in_with_apple.SignInWithApplePlugin() }
        add(engine) { io.flutter.plugins.urllauncher.UrlLauncherPlugin() }
        scheduleLate(engine)
    }

    fun registerLate(engine: FlutterEngine) {
        if (!done.add(engine)) return
        add(engine) { com.mr.flutter.plugin.filepicker.FilePickerPlugin() }
        add(engine) { co.quis.flutter_contacts.FlutterContactsPlugin() }
        add(engine) { com.baseflow.geolocator.GeolocatorPlugin() }
        add(engine) { io.flutter.plugins.googlemaps.GoogleMapsPlugin() }
        add(engine) { com.gurfdev.light_compressor_v2.LightCompressorPlugin() }
        add(engine) { io.flutter.plugins.localauth.LocalAuthPlugin() }
        add(engine) { com.crazecoder.openfile.OpenFilePlugin() }
        add(engine) { com.fluttercandies.photo_manager.PhotoManagerPlugin() }
        add(engine) { com.llfbandit.record.RecordPlugin() }
        add(engine) { dev.fluttercommunity.plus.share.SharePlusPlugin() }
        add(engine) { com.csdcorp.speech_to_text.SpeechToTextPlugin() }
        add(engine) { io.flutter.plugins.videoplayer.VideoPlayerPlugin() }
        add(engine) { io.flutter.plugins.webviewflutter.WebViewFlutterPlugin() }
    }

    private fun scheduleLate(engine: FlutterEngine) {
        if (engine.renderer.isDisplayingFlutterUi) {
            Handler(Looper.getMainLooper()).post { registerLate(engine) }
        } else {
            val listener = object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    engine.renderer.removeIsDisplayingFlutterUiListener(this)
                    Handler(Looper.getMainLooper()).post { registerLate(engine) }
                }

                override fun onFlutterUiNoLongerDisplayed() {}
            }
            engine.renderer.addIsDisplayingFlutterUiListener(listener)
        }
    }

    private fun add(engine: FlutterEngine, plugin: () -> FlutterPlugin) {
        try {
            engine.plugins.add(plugin())
        } catch (e: Exception) {
            Log.e(TAG, "Error registering plugin", e)
        }
    }
}
