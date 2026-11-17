package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Bug repro (owner 2026-11-17): a private 1:1 chat notification shows Reply only;
 * the server token already signs mark_read for private chats.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PrivateChatMarkReadTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var seq = 0

    @Before
    fun setUp() {
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
        prefs.edit().clear().putString("flutter.sis.push_inbox_owner", OWNER).commit()
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(false)
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceLocked(false)
        InstantPush.resetPacing()
    }

    private fun draw(chat: String, token: String?): Notification {
        val b = Bundle().apply {
            putString("message_id", "00000000-0000-4000-8000-%012d".format(++seq))
            putString("conversation_id", chat)
            putString("title", "Ann Sender")
            putString("body", "New message")
            putString("user_id", OWNER)
            putString("google.original_priority", "normal")
            putString("google.delivered_priority", "normal")
            putString("encrypted", "true")
            if (token != null) {
                putString("action_token", token)
                putString("action_url", "https://project.example/functions/v1/notification-action")
            }
        }
        PushArrivalReceiver().onReceive(app, Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(b) })
        return shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!
    }

    private fun titles(n: Notification) = n.actions.orEmpty().map { it.title.toString() }

    @Test
    fun `a private chat push with a mark_read token shows Mark as read and Reply`() {
        val chat = "c-pm-1"
        val token = fixtureActionToken("mark_read", chat = chat)
        val n = draw(chat, token)
        assertEquals(
            "owner report 2026-11-17: private 1:1 chat shows Reply only",
            listOf("Mark as read", "Reply"),
            titles(n)
        )
    }

    @Test
    fun `the private chat Mark as read is a broadcast to NotificationActionReceiver on sis-action read`() {
        val chat = "c-pm-2"
        val token = fixtureActionToken("mark_read", chat = chat)
        val n = draw(chat, token)
        val action = n.actions?.firstOrNull { it.title.toString() == "Mark as read" }
        assertNotNull("Mark as read action missing", action)
        val intent = action!!.actionIntent
        assertTrue("Mark as read intent is not broadcast", shadowOf(intent).isBroadcastIntent)
        val savedIntent = shadowOf(intent).savedIntent
        assertEquals(
            NotificationActionReceiver::class.java.name,
            savedIntent.component?.className
        )
        assertEquals(
            "sis-action://read/$chat",
            savedIntent.data.toString()
        )
        val index = titles(n).indexOf("Mark as read")
        assertEquals(
            NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ,
            NotificationCompat.getAction(n, index)!!.semanticAction
        )
    }

    @Test
    fun `a private chat push without a token has no Mark as read`() {
        val chat = "c-pm-3"
        val n = draw(chat, null)
        assertFalse(
            "Mark as read should not be present when token is missing",
            titles(n).contains("Mark as read")
        )
    }

    companion object {
        private const val OWNER = "member-a"
    }
}
