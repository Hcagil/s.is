package com.esd.sis

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import io.flutter.embedding.android.FlutterActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.RealObject
import org.robolectric.shadows.ShadowActivity
import org.robolectric.util.ReflectionHelpers

/**
 * The Flutter engine needs libflutter.so, which a JVM test cannot load. This shadow stands in for
 * FlutterActivity.onCreate only (it marks Activity.onCreate as called); MainActivity's own code runs.
 */
@Implements(FlutterActivity::class)
class NoEngineFlutterActivity : ShadowActivity() {
    @RealObject
    private lateinit var real: FlutterActivity

    @Implementation
    protected fun onCreate(savedInstanceState: Bundle?) {
        ReflectionHelpers.setField(Activity::class.java, real, "mCalled", true)
    }
}

/**
 * MainActivity admits only SIS's own notification taps. Written from the contract, not the code:
 * a foreign SELECT_NOTIFICATION intent, at launch or in onNewIntent, makes the sis/launch_tap "take"
 * return null (no chat opened, so no read receipt); a stamped one returns the payload as before.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [NoEngineFlutterActivity::class], instrumentedPackages = ["io.flutter.embedding.android"])
class MainActivityTapTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun tap(chat: String) = Intent(app, MainActivity::class.java)
        .setAction("SELECT_NOTIFICATION")
        .putExtra("payload", chat)
        .putExtra("notificationId", 9)

    private fun launch(intent: Intent): ActivityController<MainActivity> =
        Robolectric.buildActivity(MainActivity::class.java, intent).create()

    /** What sis/launch_tap "take" answers: its handler is `result.success(takeLaunchTap())`. */
    private fun take(a: MainActivity): String? =
        MainActivity::class.java.getDeclaredMethod("takeLaunchTap").apply { isAccessible = true }.invoke(a) as String?

    /** The actions flutter_local_notifications treats as a tap (onNewIntent and getNotificationAppLaunchDetails). */
    private val pluginTaps = setOf("SELECT_NOTIFICATION", "SELECT_FOREGROUND_NOTIFICATION")

    private fun assertNoPluginTap(i: Intent) =
        assertFalse("the plugin would read '${i.action}' as a tap and hand Dart the payload", i.action in pluginTaps)

    private fun foreground(chat: String) = tap(chat).setAction("SELECT_FOREGROUND_NOTIFICATION")

    private val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)

    @Test
    fun `our own tap at launch opens its chat`() {
        val a = launch(TapProof.stamp(app, tap("c-ma-own"))).get()
        assertEquals("c-ma-own", take(a))
    }

    @Test
    fun `a foreign tap at launch opens no chat`() {
        val a = launch(tap("c-ma-foreign")).get()
        assertNull(take(a))
        assertNoPluginTap(a.intent)
    }

    @Test
    fun `our own tap while running opens its chat`() {
        val c = launch(home)
        assertNull(take(c.get()))
        c.newIntent(TapProof.stamp(app, tap("c-ma-own-warm")))
        assertEquals("c-ma-own-warm", take(c.get()))
    }

    @Test
    fun `a foreign tap while running opens no chat`() {
        val c = launch(home)
        val sent = tap("c-ma-foreign-warm")
        c.newIntent(sent)
        assertNull(take(c.get()))
        assertNoPluginTap(sent)
    }

    @Test
    fun `a foreign tap after our own was taken opens no chat`() {
        val c = launch(TapProof.stamp(app, tap("c-ma-first")))
        assertEquals("c-ma-first", take(c.get()))
        c.newIntent(tap("c-ma-foreign-after"))
        assertNull(take(c.get()))
    }

    @Test
    fun `a foreign SELECT_FOREGROUND_NOTIFICATION at launch opens no chat`() {
        val a = launch(foreground("c-ma-fg-cold")).get()
        assertNull(take(a))
        assertNoPluginTap(a.intent)
    }

    @Test
    fun `a foreign SELECT_FOREGROUND_NOTIFICATION while running opens no chat`() {
        val c = launch(home)
        val sent = foreground("c-ma-fg-warm")
        c.newIntent(sent)
        assertNull(take(c.get()))
        assertNoPluginTap(sent)
        assertNoPluginTap(c.get().intent)
    }
}
