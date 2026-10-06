package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper

/**
 * Update 1 on Android: the native receiver is the only drawer, for a push of any priority.
 * Written from the contract, not the code:
 * - buttons: Mark as read first, then Reply. API 31+: Reply needs an unlock
 *   (isAuthenticationRequired), Mark as read never does. API 30 and older: Reply only when the
 *   phone has no secure lock.
 * - alerts: a not-high push always alerts; a high-priority push alerts only after 8 s with no
 *   draw (QUIET_MS); otherwise it lands silently.
 * - pacing: draws in arrival order, at least 300 ms apart (up to the cap); only the last queued
 *   push posts the group summary.
 * - the chat's channel from the saved settings (sis.alert_defaults / sis.alert_chats); the four
 *   pre-0.26 channels are deleted.
 * - arrival note sis.push_arrival.<id>: "now,delivered,original,q" at once, settled to ",n"
 *   (drawn) or no suffix (not drawn); not written back if Dart took it meanwhile.
 * - the edge function's payloads (test/fixtures/push/android_data_payloads.json) as drawn.
 *
 * Clock: the quiet rule runs on the wall clock, which Robolectric does not fake, so one test
 * really waits 8 s.
 */
private const val TOKEN = "v1.ticket-for-chat.sig"
private const val URL = "https://project.example/functions/v1/notification-action"
private const val OWNER = "member-a"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NativeDrawTest {
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
        secureLock(true)
        InstantPush.resetPacing()
    }

    private fun secureLock(on: Boolean) =
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(on)

    private fun nextId() = "00000000-0000-4000-8000-%012d".format(++seq)

    private fun push(
        chat: String = "c-private-chat",
        priority: String = "normal",
        id: String = nextId(),
        title: String = "Edge Team",
        withTicket: Boolean = true,
    ) = Intent("com.google.android.c2dm.intent.RECEIVE").apply {
        putExtras(
            Bundle().apply {
                putString("message_id", id)
                putString("conversation_id", chat)
                putString("title", title)
                putString("body", "hello there")
                putString("sender", "Ann Sender")
                putString("chat", title)
                putString("user_id", OWNER)
                putString("google.original_priority", priority)
                putString("google.delivered_priority", priority)
                if (withTicket) {
                    putString("action_token", TOKEN)
                    putString("action_url", URL)
                }
            },
        )
    }

    /** Inline, as when goAsync() is not available (a receiver constructed by hand). */
    private fun receive(intent: Intent) = PushArrivalReceiver().onReceive(app, intent)

    /** As FCM delivers it: a broadcast to the manifest receiver, so goAsync() is real. */
    private fun broadcast(intent: Intent) {
        intent.component = ComponentName(app, PushArrivalReceiver::class.java)
        app.sendBroadcast(intent)
    }

    private fun posted(chat: String = "c-private-chat"): Notification? =
        shadowOf(manager).getNotification(InstantPush.notificationId(chat))

    private fun titles(n: Notification) = n.actions.orEmpty().map { it.title.toString() }

    private fun note(id: String) = prefs.getString("flutter.sis.push_arrival.$id", null)

    // ---- the buttons, per API level x secure lock x priority ----

    private fun buttonsFor(priority: String): Notification {
        manager.cancelAll()
        InstantPush.resetPacing()
        receive(push(priority = priority))
        return posted()!!
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 behind a secure lock - Mark as read only, no Reply, at either priority`() {
        secureLock(true)
        for (p in listOf("normal", "high")) {
            assertEquals(p, listOf("Mark as read"), titles(buttonsFor(p)))
        }
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 with no secure lock - Mark as read, then Reply, at either priority`() {
        secureLock(false)
        for (p in listOf("normal", "high")) {
            val n = buttonsFor(p)
            assertEquals(p, listOf("Mark as read", "Reply"), titles(n))
            assertEquals(listOf(NotificationActionReceiver.KEY_REPLY), n.actions[1].remoteInputs.map { it.resultKey })
        }
    }

    private fun assertUnlockReply(n: Notification, why: String) {
        assertEquals(why, listOf("Mark as read", "Reply"), titles(n))
        val (markRead, reply) = n.actions.toList()
        assertTrue("$why: Reply needs an unlock", reply.isAuthenticationRequired)
        assertFalse("$why: Mark as read never needs one", markRead.isAuthenticationRequired)
    }

    @Test
    @Config(sdk = [31])
    fun `API 31 behind a secure lock - Reply is offered behind an unlock, at either priority`() {
        secureLock(true)
        for (p in listOf("normal", "high")) assertUnlockReply(buttonsFor(p), p)
    }

    @Test
    fun `API 34, secure lock or not - Reply always behind an unlock, at either priority`() {
        for (secure in listOf(true, false)) {
            secureLock(secure)
            for (p in listOf("normal", "high")) assertUnlockReply(buttonsFor(p), "$p secure=$secure")
        }
    }

    // ---- alerts: the 8 s quiet rule for high priority ----

    /** A group child that alerts only through its (silent) summary makes no sound itself. */
    private fun silent(n: Notification) = n.groupAlertBehavior == Notification.GROUP_ALERT_SUMMARY

    @Test
    fun `high priority right after a draw is silent, after 8 s quiet it alerts, not-high always alerts`() {
        receive(push(chat = "a"))
        assertFalse("a first push alerts", silent(posted("a")!!))
        assertFalse(InstantPush.isLoud())

        receive(push(chat = "b", priority = "high"))
        assertTrue("high within 8 s is silent", silent(posted("b")!!))

        receive(push(chat = "c"))
        assertFalse("not-high within 8 s still alerts", silent(posted("c")!!))

        Thread.sleep(8_200)
        assertTrue("8 s after the last draw the shade is quiet", InstantPush.isLoud())
        receive(push(chat = "d", priority = "high"))
        assertFalse("high after 8 s quiet alerts", silent(posted("d")!!))
    }

    @Test
    fun `after resetPacing a high-priority push alerts`() {
        receive(push(chat = "a"))
        InstantPush.resetPacing()
        assertTrue(InstantPush.isLoud())
        receive(push(chat = "b", priority = "high"))
        assertFalse(silent(posted("b")!!))
    }

    // ---- pacing and the summary, through goAsync ----

    private fun waitFor(what: String, check: () -> Boolean) {
        val until = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < until) {
            ShadowLooper.idleMainLooper()
            if (check()) return
            Thread.sleep(2)
        }
        throw AssertionError("timed out waiting for: $what")
    }

    private fun summaryLines(): List<String>? =
        shadowOf(manager).getNotification(InstantPush.SUMMARY_ID)
            ?.extras?.getCharSequenceArray(NotificationCompat.EXTRA_TEXT_LINES)
            ?.map { it.toString() }

    @Test
    fun `a burst is drawn in arrival order, at least 300 ms apart, and the summary waits for the last`() {
        val chats = (1..5).map { "burst-$it" }
        val ids = chats.map { nextId() }
        chats.forEachIndexed { i, c -> broadcast(push(chat = c, id = ids[i], title = "Chat $i")) }

        val seen = linkedMapOf<String, Long>()
        var summaryEarly: List<String>? = null
        var queuedNote: String? = null
        waitFor("all five drawn") {
            val now = System.nanoTime()
            for (c in chats) if (c !in seen && posted(c) != null) seen[c] = now
            if (seen.size in 2 until chats.size) {
                // While the tail is still queued, the summary must not have been re-posted
                // by a middle push: it never lists chat 1 (the second) yet.
                summaryLines()?.let { if (it.any { l -> l.startsWith("Chat 1") }) summaryEarly = it }
            }
            if (posted(chats.last()) == null && queuedNote == null) queuedNote = note(ids.last())
            seen.size == chats.size
        }

        assertEquals("arrival order", chats, seen.keys.toList())
        val at = seen.values.toList()
        for (i in 1 until at.size) {
            val gapMs = (at[i] - at[i - 1]) / 1_000_000
            assertTrue("draw $i came ${gapMs} ms after the one before", gapMs >= 280)
        }
        assertNull("the summary was re-posted mid-burst: $summaryEarly", summaryEarly)
        waitFor("the summary lists all five") { summaryLines()?.size == 5 }
        assertTrue(
            "a queued push's note is written at once and marked queued: $queuedNote",
            queuedNote!!.matches(Regex("""\d{13},normal,normal,q""")),
        )
        assertTrue(note(ids.last())!!.endsWith(",normal,normal,n"))
    }

    @Test
    fun `show with postSummaryNow false leaves the summary to a later push`() {
        val p = push(chat = "x").extras!!
        assertTrue(InstantPush.show(app, p, false))
        assertNotNull(posted("x"))
        assertNull(shadowOf(manager).getNotification(InstantPush.SUMMARY_ID))

        InstantPush.resetPacing()
        assertTrue(InstantPush.show(app, push(chat = "y").extras!!, true))
        val lines = summaryLines()!!
        assertEquals(2, lines.size)
    }

    @Test
    fun `a note Dart already took while the push was queued is not written back`() {
        val first = nextId()
        val second = nextId()
        broadcast(push(chat = "p1", id = first))
        broadcast(push(chat = "p2", id = second))
        waitFor("the second queued") { note(second) != null }
        prefs.edit().remove("flutter.sis.push_arrival.$second").commit() // takeArrival
        // The draw ends with the summary (it is the last queued); the settle comes right after.
        waitFor("the second drawn, summary included") { posted("p2") != null && summaryLines()?.size == 2 }
        Thread.sleep(500)
        assertNull("settled into a note nobody reads: ${note(second)}", note(second))
    }

    // ---- notes for a push that is not drawn ----

    @Test
    fun `a push that is not drawn settles its note with no suffix`() {
        val id = nextId()
        receive(push(id = id).apply { putExtra("user_id", "member-b") })
        assertNull(posted())
        val n = note(id)!!
        assertTrue(n, n.matches(Regex("""\d{13},normal,normal""")))
    }

    @Test
    fun `no valid message id - nothing drawn, no note`() {
        for (bad in listOf("", "not-a-uuid", "42")) {
            receive(push(id = bad))
            assertNull(bad, posted())
            assertNull(bad, note(bad))
        }
        receive(push().apply { removeExtra("message_id") })
        assertNull(posted())
        assertTrue(prefs.all.keys.none { it.startsWith("flutter.sis.push_arrival.") })
    }

    // ---- the chat's channel from the saved settings ----

    @Test
    fun `a custom tone draws on its own channel that plays that tone`() {
        val tone = "content://media/internal/audio/media/42"
        prefs.edit().putString("flutter.sis.alert_defaults", """{"s":true,"t":"$tone","n":"Bell","v":true}""").commit()

        receive(push(chat = "toned"))

        val n = posted("toned")!!
        assertEquals("msg-dcd38253-v1", n.channelId)
        val ch = manager.getNotificationChannel(n.channelId)
        assertEquals(Uri.parse(tone), ch.sound)
        assertTrue(ch.shouldVibrate())
        assertEquals("Messages (custom tone)", ch.name.toString())
    }

    @Test
    fun `a chat set to silent without vibration keeps its own channel, others keep theirs`() {
        prefs.edit()
            .putString("flutter.sis.alert_chats", """{"quiet":{"s":"off","v":"off"}}""")
            .commit()

        receive(push(chat = "quiet"))
        receive(push(chat = "loud"))

        assertEquals("msg-off-v0", posted("quiet")!!.channelId)
        val off = manager.getNotificationChannel("msg-off-v0")
        assertNull(off.sound)
        assertFalse(off.shouldVibrate())
        assertEquals("msg-sys-v1", posted("loud")!!.channelId)
        assertNotNull(manager.getNotificationChannel("msg-sys-v1").sound)
    }

    @Test
    fun `ensureAlertChannel creates the channel the id names, idempotently`() {
        val a = InstantPush.Alert(true, null, false)
        assertEquals("msg-sys-v0", InstantPush.ensureAlertChannel(app, a))
        assertEquals("msg-sys-v0", InstantPush.ensureAlertChannel(app, a))
        val ch = manager.getNotificationChannel("msg-sys-v0")
        assertNotNull(ch.sound)
        assertFalse(ch.shouldVibrate())
        assertEquals("Messages, no vibration", ch.name.toString())
    }

    // Its own SDK level, used by no other test, so it runs in a fresh sandbox: the deletion
    // happens once per process.
    @Test
    @Config(sdk = [32])
    fun `the four pre-Update-1 channels are deleted on the first draw`() {
        val legacy = listOf("sis-instant", "sis-instant-sound", "sis-instant-vibrate", "sis-instant-quiet")
        for (id in legacy) {
            manager.createNotificationChannel(NotificationChannel(id, id, NotificationManager.IMPORTANCE_HIGH))
        }

        receive(push())

        val left = manager.notificationChannels.map { it.id }
        for (id in legacy) assertFalse("$id still there: $left", id in left)
        assertTrue(left.toString(), "msg-sys-v1" in left)
        assertTrue(left.toString(), InstantPush.CHANNEL_SUMMARY in left)
    }

    // ---- the edge function's payloads, as drawn ----

    private val payloads = JSONObject(File("../../test/fixtures/push/android_data_payloads.json").readText())

    private fun deliver(name: String, chat: String): Notification {
        val p = payloads.getJSONObject(name)
        val i = Intent("com.google.android.c2dm.intent.RECEIVE").apply {
            putExtras(
                Bundle().apply {
                    for (k in p.keys()) putString(k, p.getString(k))
                    putString("conversation_id", chat)
                    putString("user_id", OWNER)
                    putString("message_id", nextId())
                },
            )
        }
        receive(i)
        return posted(chat)!!
    }

    private fun style(n: Notification) = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!

    @Test
    fun `group payload - the chat is the title, the line is the sender's`() {
        val n = deliver("group_full", "g-team")
        val s = style(n)
        assertEquals("Edge Team", s.conversationTitle.toString())
        assertTrue(s.isGroupConversation)
        assertEquals(listOf("Ann Sender"), s.messages.map { it.person?.name?.toString() })
        assertEquals(listOf("edge seam hello"), s.messages.map { it.text.toString() })
        assertEquals(listOf("Edge Team: Ann Sender: edge seam hello"), summaryLines())
    }

    @Test
    fun `group payload without the text - the sender's New message, the text never shown`() {
        val n = deliver("group_sender", "g-team")
        val s = style(n)
        assertEquals("Edge Team", s.conversationTitle.toString())
        assertEquals(listOf("New message"), s.messages.map { it.text.toString() })
        assertEquals(listOf("Ann Sender"), s.messages.map { it.person?.name?.toString() })
    }

    @Test
    fun `payload naming nobody - SIS, no sender, no chat`() {
        val n = deliver("group_none", "g-team")
        val all = n.extras.keySet().joinToString { "${n.extras.get(it)}" } + style(n).messages.joinToString { "${it.person?.name} ${it.text}" }
        assertFalse(style(n).isGroupConversation)
        assertFalse(all, all.contains("Ann"))
        assertFalse(all, all.contains("Edge Team"))
    }

    @Test
    fun `direct payload - the person is the title, not a group`() {
        val n = deliver("direct_full", "d-ann")
        val s = style(n)
        assertFalse(s.isGroupConversation)
        assertNull(s.conversationTitle)
        assertEquals(listOf("Ann Sender"), s.messages.map { it.person?.name?.toString() })
        assertEquals(listOf("edge direct hello"), s.messages.map { it.text.toString() })
    }

    // ---- replyOffered is the rule the drawer applies ----

    @Test
    fun `replyOffered matches the rule`() {
        assertFalse(InstantPush.replyOffered(30, true))
        assertTrue(InstantPush.replyOffered(30, false))
        assertTrue(InstantPush.replyOffered(31, true))
        assertNotEquals(InstantPush.replyOffered(30, true), InstantPush.replyOffered(31, true))
    }
}
