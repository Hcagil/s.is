package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * PushArrivalReceiver + InstantPush.show on Android's framework (Robolectric), from the 0.30.7
 * contract (docs/DECISIONS.md), not the code. The receiver is driven as FCM's broadcast reaches
 * it: an Intent whose extras are the push's data plus FCM's google.* keys.
 *
 * Response budget: the notification must be on the shade when onReceive returns -- no job, no
 * handler, no deferral.
 */
// FCM message ids are UUIDs; the receiver ignores anything else.
private const val MSG = "6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d"
private const val OLD_23H = "00000000-0000-0000-0000-000000000023"
private const val OLD_25H = "00000000-0000-0000-0000-000000000025"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PushArrivalReceiverTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val chat = "c-private-chat"
    private val chatId = 1411012581 // test/fixtures/instant_push_vectors.json

    @Before
    fun setUp() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(manager).setNotificationsEnabled(true)
        backgrounded()
        prefs.edit().clear().putString("flutter.sis.push_inbox_owner", "member-a").commit()
    }

    /** The app's process as Android reports it while the app is not on screen. */
    private fun backgrounded() = processImportance(ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED)

    private fun processImportance(importance: Int) {
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        shadowOf(am).setProcesses(
            listOf(
                ActivityManager.RunningAppProcessInfo().apply {
                    processName = app.packageName
                    pid = android.os.Process.myPid()
                    this.importance = importance
                },
            ),
        )
    }

    private fun push(
        id: String = MSG,
        priority: String? = null,
        user: String? = "member-a",
        extra: Bundle.() -> Unit = {},
    ) = Intent("com.google.android.c2dm.intent.RECEIVE").apply {
        putExtras(
            Bundle().apply {
                putString("message_id", id)
                putString("conversation_id", chat)
                putString("title", "Edge Team")
                putString("body", "hello there")
                putString("sender", "Ann Sender")
                putString("chat", "Edge Team")
                if (user != null) putString("user_id", user)
                if (priority != null) {
                    putString("google.original_priority", priority)
                    putString("google.delivered_priority", priority)
                }
                extra()
            },
        )
    }

    private fun receive(intent: Intent) = PushArrivalReceiver().onReceive(app, intent)

    private fun shade() = shadowOf(manager).allNotifications

    private fun note(id: String = MSG) = prefs.getString("flutter.sis.push_arrival.$id", null)

    @Test
    fun `a not-high push of ours is on the shade when onReceive returns, as Dart would draw it`() {
        prefs.edit()
            .putString("flutter.sis.alert_chats", """{"$chat":{"s":"off","v":"byDefault"}}""")
            .commit()

        receive(push(priority = "normal"))

        // The chat and its group summary (id 0), as the Dart side posts them.
        assertEquals(2, shade().size)
        assertNotNull(shadowOf(manager).getNotification(InstantPush.SUMMARY_ID))
        val posted = shadowOf(manager).getNotification(chatId)
        assertNotNull("posted under the Dart side's id for the chat", posted)
        assertEquals("sis.messages", posted.group)
        assertEquals("sound off, vibration on", InstantPush.CHANNEL_VIBRATE, posted.channelId)
        val channel = manager.getNotificationChannel(InstantPush.CHANNEL_VIBRATE)
        assertNotNull(channel)
        assertNull("the vibrate-only channel makes no sound", channel.sound)
        assertTrue(channel.shouldVibrate())
        // MessagingStyle, as the Dart side draws a group: the group is the conversation, the
        // sender is the line's person.
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(posted)!!
        assertEquals("Edge Team", style.conversationTitle.toString())
        assertTrue(style.isGroupConversation)
        assertEquals(listOf("hello there"), style.messages.map { it.text.toString() })
        assertEquals("Ann Sender", style.messages.single().person!!.name.toString())

        // Tap: the same intent flutter_local_notifications builds, so Dart opens the chat.
        val tap = shadowOf(posted.contentIntent)
        assertTrue(tap.isActivityIntent)
        assertEquals("SELECT_NOTIFICATION", tap.savedIntent.action)
        assertEquals(chat, tap.savedIntent.getStringExtra("payload"))

        assertTrue("the receipt learns the receiver drew it: ${note()}", note()!!.endsWith(",n"))
    }

    @Test
    fun `a push with no priority at all is drawn too`() {
        receive(push(priority = null))

        assertNotNull(shadowOf(manager).getNotification(chatId))
        assertEquals(InstantPush.CHANNEL_BOTH, shadowOf(manager).getNotification(chatId).channelId)
    }

    @Test
    fun `high priority is left to Dart`() {
        receive(push(priority = "high"))

        assertTrue(shade().isEmpty())
        assertFalse(note()!!.endsWith(",n"))
        assertTrue(note()!!.endsWith(",high,high"))
    }

    @Test
    fun `a push for another member draws nothing`() {
        receive(push(priority = "normal", user = "member-b"))

        assertTrue(shade().isEmpty())
        assertFalse(note()!!.endsWith(",n"))
    }

    @Test
    fun `nobody signed in draws nothing`() {
        prefs.edit().remove("flutter.sis.push_inbox_owner").commit()

        receive(push(priority = "normal"))

        assertTrue(shade().isEmpty())
    }

    @Test
    fun `a push with a notification block is not ours`() {
        receive(push(priority = "normal") { putString("gcm.n.title", "Edge Team") })

        assertTrue(shade().isEmpty())
    }

    @Test
    fun `notifications turned off draws nothing`() {
        shadowOf(manager).setNotificationsEnabled(false)

        receive(push(priority = "normal"))

        assertTrue(shade().isEmpty())
        assertFalse(note()!!.endsWith(",n"))
    }

    @Test
    fun `the app in the foreground draws nothing`() {
        processImportance(ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND)

        receive(push(priority = "normal"))

        assertTrue(shade().isEmpty())
        assertFalse(note()!!.endsWith(",n"))
    }

    @Test
    fun `an unread arrival note survives 23 hours and is gone after 25`() {
        val hour = 60L * 60 * 1000
        val now = System.currentTimeMillis()
        prefs.edit()
            .putString("flutter.sis.push_arrival.$OLD_23H", "${now - 23 * hour},?,?,n")
            .putString("flutter.sis.push_arrival.$OLD_25H", "${now - 25 * hour},?,?,n")
            .commit()

        receive(push(id = "3b2e9a40-7f11-4c8e-b2a1-9d5c0e6f4a77", priority = "normal"))

        assertNotNull("Doze can hold the Dart job this long", note(OLD_23H))
        assertNull(note(OLD_25H))
        assertNotNull(note("3b2e9a40-7f11-4c8e-b2a1-9d5c0e6f4a77"))
    }

    private val inboxKey = "flutter.sis.push_inbox.member-a"

    private fun lines(): List<NotificationCompat.MessagingStyle.Message> =
        NotificationCompat.MessagingStyle
            .extractMessagingStyleFromNotification(shadowOf(manager).getNotification(chatId))!!
            .messages

    @Test
    fun `N pushes draw one MessagingStyle with N lines, a summary and the stored inbox`() {
        val ids = listOf(MSG, "3b2e9a40-7f11-4c8e-b2a1-9d5c0e6f4a77", "00000000-0000-0000-0000-0000000000a3")
        ids.forEachIndexed { i, id ->
            receive(push(id = id, priority = "normal") { putString("body", "line $i") })
        }

        assertEquals(listOf("line 0", "line 1", "line 2"), lines().map { it.text.toString() })
        assertEquals(List(3) { "Ann Sender" }, lines().map { it.person?.name?.toString() })

        val summary = shadowOf(manager).getNotification(InstantPush.SUMMARY_ID)
        assertNotNull("the group summary is posted under id 0", summary)
        assertEquals(InstantPush.CHANNEL_SUMMARY, summary.channelId)
        assertEquals(InstantPush.GROUP, summary.group)
        assertEquals(2, shade().size)

        val chats = PushInbox.parse(prefs.getString(inboxKey, null))
        assertEquals(1, chats.length())
        val stored = chats.getJSONObject(0)
        assertEquals(chat, stored.getString("c"))
        assertEquals(3, stored.getInt("n"))
        assertEquals(0, stored.getInt("p"))
        val l = stored.getJSONArray("l")
        assertEquals(ids, (0 until l.length()).map { l.getJSONObject(it).getString("m") })
    }

    @Test
    fun `a redelivered push adds no line`() {
        receive(push(priority = "normal"))
        receive(push(priority = "normal"))

        assertEquals(1, lines().size)
        assertEquals(1, PushInbox.parse(prefs.getString(inboxKey, null)).getJSONObject(0).getInt("n"))
    }

    @Test
    fun `lines Dart stored before are kept and the new one goes last`() {
        prefs.edit().putString(
            inboxKey,
            """[{"c":"$chat","t":"Edge Team","g":true,"l":[{"s":"Bo","x":"earlier","a":1}],"n":1,"p":1}]""",
        ).commit()

        receive(push(priority = "normal"))

        assertEquals(listOf("earlier", "hello there"), lines().map { it.text.toString() })
        assertEquals(listOf("Bo", "Ann Sender"), lines().map { it.person?.name?.toString() })
        val stored = PushInbox.parse(prefs.getString(inboxKey, null)).getJSONObject(0)
        assertEquals(2, stored.getInt("n"))
        assertEquals(1, stored.getInt("p"))
    }
}
