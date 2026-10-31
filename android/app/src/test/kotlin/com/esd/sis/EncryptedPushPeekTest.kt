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
import org.junit.After
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
 * Private Chats 4b G: an encrypted push with ciphertext (`ct`, `ot`) is peeked through PeekRunner
 * (here its test seam `PeekRunner.override`). Written from the contract, not the code:
 * - the notification line shows the peeked text;
 * - the push inbox (FlutterSharedPreferences) only ever holds the locked text;
 * - visibility PRIVATE; the public version: title "SIS", text the fallback, same icon and colour;
 * - one Reply (the app sends it locked) and no Mark as read (Group I);
 * - a null peek draws today's locked notification;
 * - without ct/ot, or when not encrypted, the peek is never asked.
 */
private const val OWNER = "member-a"
private const val SECRET = "meet at the old bridge at nine"
private const val LOCKED = "New message"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EncryptedPushPeekTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val asked = mutableListOf<Bundle>()

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
        // No secure lock: Reply would be offered, so its absence means the lock rule.
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(false)
        InstantPush.resetPacing()
        peekReturns(SECRET)
    }

    @After
    fun tearDown() {
        PeekRunner.override = null
    }

    private fun peekReturns(text: String?) {
        PeekRunner.override = { b -> asked.add(b); text }
    }

    private fun extras(
        chat: String,
        encrypted: String? = "true",
        ct: String? = "AwogQmFzZTY0Q2lwaGVydGV4dA==",
        ot: String? = "1",
    ) = Bundle().apply {
        // Unique per run: InstantPush keeps peeked text by message id in memory across tests.
        putString("message_id", java.util.UUID.randomUUID().toString())
        putString("conversation_id", chat)
        putString("title", "Ann Sender")
        putString("body", "server placeholder body")
        putString("sender", "Ann Sender")
        putString("chat", "Ann Sender")
        putString("user_id", OWNER)
        putString("google.original_priority", "normal")
        putString("google.delivered_priority", "normal")
        putString("action_token", "v1.ticket-for-chat.sig")
        putString("action_url", "https://project.example/functions/v1/notification-action")
        if (encrypted != null) putString("encrypted", encrypted)
        if (ct != null) putString("ct", ct)
        if (ot != null) putString("ot", ot)
    }

    private fun show(b: Bundle): Notification {
        InstantPush.show(app, b)
        return shadowOf(manager).getNotification(InstantPush.notificationId(b.getString("conversation_id")!!))!!
    }

    private fun line(n: Notification) =
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!.messages.last()

    private fun allPrefs(): String = prefs.all.entries.joinToString("\n") { "${it.key}=${it.value}" }

    @Test
    fun `the peeked text is the notification line under the sender's name`() {
        val n = show(extras("c-peek-1"))
        assertEquals(SECRET, line(n).text.toString())
        assertEquals("Ann Sender", line(n).person!!.name.toString())
        assertEquals(1, asked.size)
        assertEquals("c-peek-1", asked.single().getString("conversation_id"))
    }

    @Test
    fun `the push inbox holds only the locked text, never the peeked one`() {
        show(extras("c-peek-2"))
        val inbox = prefs.getString("flutter.sis.push_inbox.$OWNER", null)
        assertNotNull("push inbox written", inbox)
        assertTrue(inbox, inbox!!.contains(LOCKED))
        assertFalse(inbox, inbox.contains("\uD83D\uDD12"))
        assertFalse(allPrefs(), allPrefs().contains(SECRET))
    }

    @Test
    fun `the lock screen version is private and shows SIS and the fallback string`() {
        val n = show(extras("c-peek-3"))
        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility)
        val pub = n.publicVersion
        assertNotNull("public version set", pub)
        assertEquals("SIS", pub!!.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
        val text = pub.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        assertEquals(app.getString(R.string.notification_fallback), text)
        assertEquals(LOCKED, text)
        assertEquals(n.smallIcon.resId, pub.smallIcon.resId)
        assertEquals(n.color, pub.color)
        assertFalse(pub.extras.toString().contains(SECRET))
        assertFalse(pub.extras.toString().contains("Ann Sender"))
    }

    @Test
    fun `a peeked push has one Reply and no Mark as read`() =
        assertEquals(listOf("Reply"), show(extras("c-peek-4")).actions.orEmpty().map { it.title.toString() })

    @Test
    fun `a null peek draws today's locked notification`() {
        peekReturns(null)
        val n = show(extras("c-peek-5"))
        assertEquals(1, asked.size)
        assertEquals(LOCKED, line(n).text.toString())
        assertEquals(listOf("Reply"), n.actions.orEmpty().map { it.title.toString() })
    }

    @Test
    fun `without ct the peek is never asked and the push is locked`() {
        val n = show(extras("c-peek-6", ct = null))
        assertEquals(LOCKED, line(n).text.toString())
        assertEquals(0, asked.size)
    }

    @Test
    fun `without ot, or ot other than 0 or 1, the peek is never asked`() {
        assertEquals(LOCKED, line(show(extras("c-peek-7", ot = null))).text.toString())
        assertEquals(LOCKED, line(show(extras("c-peek-8", ot = "2"))).text.toString())
        assertEquals(0, asked.size)
    }

    @Test
    fun `a pre-key push (ot 0) is peeked too`() {
        assertEquals(SECRET, line(show(extras("c-peek-9", ot = "0"))).text.toString())
        assertEquals(1, asked.size)
    }

    @Test
    fun `a push that is not encrypted never asks the peek, even with ct and ot`() {
        val n = show(extras("c-peek-10", encrypted = null))
        show(extras("c-peek-11", encrypted = "false"))
        assertEquals(0, asked.size)
        assertEquals("server placeholder body", line(n).text.toString())
    }

    @Test
    fun `through the production receiver the peeked text is shown too`() {
        PushArrivalReceiver().onReceive(
            app,
            Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(extras("c-peek-12")) },
        )
        val n = shadowOf(manager).getNotification(InstantPush.notificationId("c-peek-12"))!!
        assertEquals(SECRET, line(n).text.toString())
        assertFalse(allPrefs(), allPrefs().contains(SECRET))
    }

    @Test
    fun `PeekRunner wanted only for encrypted true with ct, ot 0 or 1 and all ids`() {
        assertTrue(PeekRunner.wanted(extras("w1")))
        assertTrue(PeekRunner.wanted(extras("w2", ot = "0")))
        assertFalse(PeekRunner.wanted(extras("w3", ct = null)))
        assertFalse(PeekRunner.wanted(extras("w4", ct = "")))
        assertFalse(PeekRunner.wanted(extras("w5", ot = null)))
        assertFalse(PeekRunner.wanted(extras("w6", ot = "2")))
        assertFalse(PeekRunner.wanted(extras("w7", encrypted = null)))
        assertFalse(PeekRunner.wanted(extras("w8", encrypted = "false")))
        for (key in listOf("user_id", "conversation_id", "message_id")) {
            assertFalse(key, PeekRunner.wanted(extras("w9").apply { remove(key) }))
        }
    }
}
