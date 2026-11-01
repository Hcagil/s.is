package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.NotificationManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * HuaweiBadge from its contract, not its code. The Huawei launcher is stood in for by a content
 * provider under its real authority, as EMUI exposes it: it records every call(), and can be told
 * to throw, as a phone without that launcher (or a launcher that refuses) does.
 */
private const val AUTHORITY = "com.huawei.android.launcher.settings"

class FakeHuaweiLauncher : ContentProvider() {
    data class Call(val method: String, val extras: Bundle?)

    companion object {
        val calls = mutableListOf<Call>()
        var failWith: RuntimeException? = null
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        calls += Call(method, extras)
        failWith?.let { throw it }
        return Bundle()
    }

    override fun onCreate() = true
    override fun query(u: Uri, p: Array<String>?, s: String?, a: Array<String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<String>?) = 0
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HuaweiBadgeTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        FakeHuaweiLauncher.calls.clear()
        FakeHuaweiLauncher.failWith = null
        Robolectric.buildContentProvider(FakeHuaweiLauncher::class.java).create(AUTHORITY)
    }

    private fun sentCounts() = FakeHuaweiLauncher.calls.map { it.extras!!.getInt("badgenumber") }

    @Test
    fun `the count reaches the Huawei launcher with this app's launcher activity`() {
        HuaweiBadge.set(app, 5)

        val call = FakeHuaweiLauncher.calls.single()
        assertEquals("change_badge", call.method)
        val extras = call.extras!!
        assertEquals(app.packageName, extras.getString("package"))
        assertEquals("com.esd.sis.MainActivity", extras.getString("class"))
        assertEquals(5, extras.getInt("badgenumber"))
    }

    @Test
    fun `the count is clamped to 0 to 99`() {
        HuaweiBadge.set(app, -3)
        HuaweiBadge.set(app, 0)
        HuaweiBadge.set(app, 99)
        HuaweiBadge.set(app, 150)

        assertEquals(listOf(0, 0, 99, 99), sentCounts())
    }

    @Test
    fun `a launcher that throws does not crash the app`() {
        for (e in listOf(SecurityException("no"), IllegalArgumentException("Unknown authority"))) {
            FakeHuaweiLauncher.failWith = e
            HuaweiBadge.set(app, 3)
        }
        assertEquals(2, FakeHuaweiLauncher.calls.size)
    }
}

/** The push path: a `badge` value in the push's data reaches the launcher. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HuaweiBadgePushTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    @Before
    fun setUp() {
        FakeHuaweiLauncher.calls.clear()
        FakeHuaweiLauncher.failWith = null
        Robolectric.buildContentProvider(FakeHuaweiLauncher::class.java).create(AUTHORITY)
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(manager).setNotificationsEnabled(true)
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        shadowOf(am).setProcesses(
            listOf(
                ActivityManager.RunningAppProcessInfo().apply {
                    processName = app.packageName
                    pid = android.os.Process.myPid()
                    importance = ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED
                },
            ),
        )
        prefs.edit().clear().putString("flutter.sis.push_inbox_owner", "member-a").commit()
        InstantPush.resetPacing()
    }

    // Same shape as PushArrivalReceiverTest: FCM data values arrive as strings.
    private fun receive(badge: String?) = PushArrivalReceiver().onReceive(
        app,
        Intent("com.google.android.c2dm.intent.RECEIVE").apply {
            putExtras(
                Bundle().apply {
                    putString("message_id", "6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d")
                    putString("conversation_id", "c-private-chat")
                    putString("title", "Edge Team")
                    putString("body", "hello there")
                    putString("sender", "Ann Sender")
                    putString("chat", "Edge Team")
                    putString("user_id", "member-a")
                    putString("google.original_priority", "normal")
                    putString("google.delivered_priority", "normal")
                    if (badge != null) putString("badge", badge)
                },
            )
        },
    )

    private fun drawn() = assertTrue("the push itself is still drawn", shadowOf(manager).allNotifications.isNotEmpty())

    @Test
    fun `a numeric badge is applied`() {
        receive("7")
        drawn()
        assertEquals(listOf(7), FakeHuaweiLauncher.calls.map { it.extras!!.getInt("badgenumber") })
    }

    @Test
    fun `a badge of 0 is applied`() {
        receive("0")
        drawn()
        assertEquals(listOf(0), FakeHuaweiLauncher.calls.map { it.extras!!.getInt("badgenumber") })
    }

    @Test
    fun `no badge sets nothing`() {
        receive(null)
        drawn()
        assertEquals(0, FakeHuaweiLauncher.calls.size)
    }

    @Test
    fun `a badge that is not a number sets nothing`() {
        receive("seven")
        drawn()
        assertEquals(0, FakeHuaweiLauncher.calls.size)
    }
}
