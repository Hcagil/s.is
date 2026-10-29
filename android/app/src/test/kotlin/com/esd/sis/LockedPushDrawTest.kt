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
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Private Chats 4a: a push of an encrypted chat (data `encrypted == "true"`). Written from the
 * contract, not the code:
 * - its line is the fallback string ("New message", values-tr "Yeni mesaj") under the
 *   sender's name, never the server body;
 * - it has one Reply (Group I: the app sends it locked) and no Mark as read, even with a valid
 *   action ticket;
 * - every other push is unchanged: its body, and both buttons;
 * - every chat push, plain or private, is VISIBILITY_PRIVATE with a public version titled
 *   "SIS", text the fallback, same small icon and colour, never the chat name;
 * - strings: notification_fallback, notification_public_title "SIS"; notification_locked gone.
 */
private const val TOKEN = "v1.ticket-for-chat.sig"
private const val URL = "https://project.example/functions/v1/notification-action"
private const val OWNER = "member-a"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LockedPushDrawTest {
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
        // No secure lock: Reply is offered on every API level, so its absence means the lock rule.
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(false)
        InstantPush.resetPacing()
    }

    private fun push(chat: String, encrypted: String?) = Intent("com.google.android.c2dm.intent.RECEIVE").apply {
        putExtras(
            Bundle().apply {
                putString("message_id", "00000000-0000-4000-8000-%012d".format(++seq))
                putString("conversation_id", chat)
                putString("title", "Ann Sender")
                putString("body", "server placeholder body")
                putString("sender", "Ann Sender")
                putString("chat", "Ann Sender")
                putString("user_id", OWNER)
                putString("google.original_priority", "normal")
                putString("google.delivered_priority", "normal")
                putString("action_token", TOKEN)
                putString("action_url", URL)
                if (encrypted != null) putString("encrypted", encrypted)
            },
        )
    }

    private fun draw(chat: String, encrypted: String?): Notification {
        PushArrivalReceiver().onReceive(app, push(chat, encrypted))
        return shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!
    }

    private fun buttons(n: Notification) = n.actions.orEmpty().map { it.title.toString() }

    private fun line(n: Notification) =
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!.messages.last()

    @Test
    fun `an encrypted push shows the locked text with the sender's name`() {
        val l = line(draw("c-locked-1", "true"))
        assertEquals("New message", l.text.toString())
        assertEquals("Ann Sender", l.person!!.name.toString())
    }

    @Test
    fun `an encrypted push has one Reply and no Mark as read`() =
        assertEquals(listOf("Reply"), buttons(draw("c-locked-2", "true")))

    @Test
    @Config(qualifiers = "tr")
    fun `in Turkish the locked text is the values-tr string`() =
        assertEquals("Yeni mesaj", line(draw("c-locked-tr", "true")).text.toString())

    @Test
    fun `a push without the flag keeps its body and both buttons`() {
        val n = draw("c-plain-1", null)
        assertEquals("server placeholder body", line(n).text.toString())
        assertEquals(setOf("Mark as read", "Reply"), buttons(n).toSet())
    }

    @Test
    fun `encrypted other than true is an ordinary push`() {
        val n = draw("c-plain-2", "false")
        assertEquals("server placeholder body", line(n).text.toString())
        assertTrue(buttons(n).containsAll(listOf("Mark as read", "Reply")))
    }

    private fun assertPublic(n: Notification, fallback: String) {
        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility)
        val pub = n.publicVersion!!
        assertEquals("SIS", pub.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
        assertEquals(fallback, pub.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
        assertEquals(n.smallIcon.resId, pub.smallIcon.resId)
        assertEquals(n.color, pub.color)
        assertFalse(pub.extras.toString(), pub.extras.toString().contains("Ann Sender"))
        assertFalse(pub.extras.toString(), pub.extras.toString().contains("server placeholder body"))
    }

    @Test
    fun `a plain push is private with the SIS public version`() = assertPublic(draw("c-pub-1", null), "New message")

    @Test
    fun `a private chat push is private with the SIS public version`() =
        assertPublic(draw("c-pub-2", "true"), "New message")

    @Test
    @Config(qualifiers = "tr")
    fun `in Turkish the public version shows the values-tr fallback`() =
        assertPublic(draw("c-pub-tr", null), "Yeni mesaj")

    @Test
    fun `the strings are the contract's and notification_locked is gone`() {
        assertEquals("New message", app.getString(R.string.notification_fallback))
        assertEquals("SIS", app.getString(R.string.notification_public_title))
        assertEquals(0, app.resources.getIdentifier("notification_locked", "string", app.packageName))
    }

    private fun noLockEmoji() = R.string::class.java.fields.forEach { f ->
        val text = app.getString(f.getInt(null))
        assertFalse("${f.name}: $text", text.contains("\uD83D\uDD12"))
    }

    @Test
    fun `no app string holds a lock emoji`() = noLockEmoji()

    @Test
    @Config(qualifiers = "tr")
    fun `no Turkish app string holds a lock emoji`() = noLockEmoji()
}
