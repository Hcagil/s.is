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
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Which Reply a plain (not locked) push draws, decided by the action token's `a` list:
 * `reply` -> Mark as read + plain Reply; no `reply` (or unreadable token) with a user_id ->
 * Mark as read + the locked Reply (EncryptedReplyActivity); no user_id -> the push is not drawn (owner gate).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PlainPushReplyChoiceTest {
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
        prefs.edit().clear().putString("flutter.sis.push_inbox_owner", "member-a").commit()
        val keyguard = shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager)
        keyguard.setIsDeviceSecure(false)
        keyguard.setIsDeviceLocked(false)
        InstantPush.resetPacing()
    }

    private fun draw(chat: String, token: String, user: String? = "member-a"): Notification =
        drawOrNull(chat, token, user)!!

    private fun drawOrNull(chat: String, token: String, user: String? = "member-a"): Notification? {
        val b = Bundle().apply {
            putString("message_id", "00000000-0000-4000-8000-%012d".format(++seq))
            putString("conversation_id", chat)
            putString("title", "Ann Sender")
            putString("body", "plain words")
            putString("sender", "Ann Sender")
            putString("chat", "Ann Sender")
            if (user != null) putString("user_id", user)
            putString("google.original_priority", "normal")
            putString("google.delivered_priority", "normal")
            putString("action_token", token)
            putString("action_url", "https://project.example/functions/v1/notification-action")
        }
        PushArrivalReceiver().onReceive(app, Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(b) })
        return shadowOf(manager).getNotification(InstantPush.notificationId(chat))
    }

    private fun titles(n: Notification) = n.actions.orEmpty().map { it.title.toString() }

    private fun broadcasts(n: Notification) =
        n.actions.orEmpty().filter { shadowOf(it.actionIntent).isBroadcastIntent }.map { it.title.toString() }

    private fun lockedReplyTarget(n: Notification): String? {
        val reply = n.actions.single { it.title.toString() == "Reply" }
        val pi = shadowOf(reply.actionIntent)
        check(pi.isActivityIntent) { "Reply must be an activity PendingIntent" }
        return pi.savedIntent.component?.className
    }

    @Test
    fun `reply in the token gives Mark as read and the plain Reply`() {
        val n = draw("c-ch-1", fixtureActionToken("mark_read", "reply"))
        assertEquals(listOf("Mark as read", "Reply"), broadcasts(n))
        assertEquals(listOf("Mark as read", "Reply"), titles(n))
    }

    @Test
    fun `no reply in the token gives Mark as read and the locked Reply`() {
        val n = draw("c-ch-2", fixtureActionToken("mark_read"))
        assertEquals(listOf("Mark as read", "Reply"), titles(n))
        assertEquals(listOf("Mark as read"), broadcasts(n))
        assertEquals(EncryptedReplyActivity::class.java.name, lockedReplyTarget(n))
    }

    @Test
    fun `a push with no user_id is not drawn at all`() {
        assertNull("owner-less push must draw nothing", drawOrNull("c-ch-3", fixtureActionToken("mark_read"), user = null))
    }

    @Test
    fun `a token that cannot be read draws no plain Reply but keeps Mark as read`() {
        val notJson = "v1." + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString("not json".toByteArray()) + ".sig"
        val noList = "v1." + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString("""{"u":"member-a"}""".toByteArray()) + ".sig"
        val bad = listOf("v1.ticket-for-chat.sig", "garbage", "v1..sig", notJson, noList)
        for ((i, token) in bad.withIndex()) {
            val n = draw("c-ch-4-$i", token)
            assertEquals("token '$token'", listOf("Mark as read"), broadcasts(n))
            assertEquals("token '$token'", EncryptedReplyActivity::class.java.name, lockedReplyTarget(n))
        }
    }
}
