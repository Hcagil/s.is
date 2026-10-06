package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.test.core.app.ApplicationProvider
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.json.JSONObject
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
import org.robolectric.shadows.ShadowLog
import org.robolectric.shadows.ShadowLooper

/**
 * The Mark as read / Reply buttons on a notification the native side draws (no Dart runs), from
 * the slice 11b contract, not the code: the buttons exist only when the push carried a ticket
 * (action_token plus an https action_url); each button is a broadcast to the non-exported
 * NotificationActionReceiver; Reply carries a RemoteInput under "sis_reply"; ActionClient maps a
 * status the same way the Dart client does, posts only to https, never throws, logs nothing; a
 * reply that did not go through says "Not sent" on the chat's notification.
 */
private const val MSG = "6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d"
private const val TOKEN = "v1.ticket-for-chat.sig"
private const val URL = "https://project.example/functions/v1/notification-action"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NotificationActionTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val chat = "c-private-chat"
    private val chatId = InstantPush.notificationId(chat)

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
        ShadowLog.clear()
    }

    private fun push(token: String? = TOKEN, url: String? = URL) =
        Intent("com.google.android.c2dm.intent.RECEIVE").apply {
            putExtras(
                Bundle().apply {
                    putString("message_id", MSG)
                    putString("conversation_id", chat)
                    putString("title", "Edge Team")
                    putString("body", "hello there")
                    putString("sender", "Ann Sender")
                    putString("chat", "Edge Team")
                    putString("user_id", "member-a")
                    putString("google.original_priority", "normal")
                    putString("google.delivered_priority", "normal")
                    if (token != null) putString("action_token", token)
                    if (url != null) putString("action_url", url)
                },
            )
        }

    private fun arrives(token: String? = TOKEN, url: String? = URL) =
        PushArrivalReceiver().onReceive(app, push(token, url))

    private fun posted() = shadowOf(manager).getNotification(chatId)

    private fun lines(n: android.app.Notification) =
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)
            ?.messages?.map { it.text.toString() }
            ?: listOf(n.extras.getCharSequence(NotificationCompat.EXTRA_TEXT).toString())

    // ---- ActionClient: the same status map as the Dart client ----

    @Test
    fun `status map matches the Dart client`() {
        val cases = mapOf(
            200 to ActionResult.DONE,
            201 to ActionResult.REJECTED,
            204 to ActionResult.REJECTED,
            400 to ActionResult.REJECTED,
            401 to ActionResult.REJECTED,
            403 to ActionResult.REJECTED,
            404 to ActionResult.REJECTED,
            409 to ActionResult.REJECTED,
            428 to ActionResult.REJECTED,
            429 to ActionResult.RETRY,
            430 to ActionResult.REJECTED,
            500 to ActionResult.RETRY,
            503 to ActionResult.RETRY,
            599 to ActionResult.RETRY,
        )
        for ((status, want) in cases) assertEquals("status $status", want, ActionClient.resultFor(status))
    }

    @Test
    fun `mark_read body carries the ticket, the chat and the action only`() {
        val json = JSONObject(ActionClient.requestBody(TOKEN, chat, false, null, null))
        assertEquals(setOf("token", "conversation_id", "action"), json.keys().asSequence().toSet())
        assertEquals(TOKEN, json.getString("token"))
        assertEquals(chat, json.getString("conversation_id"))
        assertEquals("mark_read", json.getString("action"))
    }

    @Test
    fun `reply body carries the id and the text`() {
        val id = "0b6a1f8e-3c2d-4e5f-8a9b-665544332211"
        val json = JSONObject(ActionClient.requestBody(TOKEN, chat, true, id, "on my way \"quoted\""))
        assertEquals(
            setOf("token", "conversation_id", "action", "id", "body"),
            json.keys().asSequence().toSet(),
        )
        assertEquals("reply", json.getString("action"))
        assertEquals(id, json.getString("id"))
        assertEquals("on my way \"quoted\"", json.getString("body"))
    }

    @Test
    fun `post refuses a url that is not https, without a request`() {
        assertEquals(ActionResult.REJECTED, ActionClient.post("http://127.0.0.1:9/x", "{}"))
        assertEquals(ActionResult.REJECTED, ActionClient.post("not a url", "{}"))
        assertTrue("logs nothing: ${ShadowLog.getLogs()}", ShadowLog.getLogs().isEmpty())
    }

    @Test
    fun `post to an https server that does not answer is retry, never a throw, logs nothing`() {
        // Port 1 on loopback: the connection is refused.
        assertEquals(ActionResult.RETRY, ActionClient.post("https://127.0.0.1:1/x", "{}"))
        assertTrue("logs nothing: ${ShadowLog.getLogs()}", ShadowLog.getLogs().isEmpty())
    }

    // ---- the buttons on the shade ----

    @Test
    fun `a push with a ticket gets Mark as read and Reply`() {
        arrives()
        val n = posted()
        assertNotNull(n)
        val actions = n.actions!!.toList()
        assertEquals(listOf("Mark as read", "Reply"), actions.map { it.title.toString() })

        val (markRead, reply) = actions
        assertTrue(markRead.remoteInputs.isNullOrEmpty())
        assertEquals(listOf(NotificationActionReceiver.KEY_REPLY), reply.remoteInputs.map { it.resultKey })
        assertEquals("sis_reply", NotificationActionReceiver.KEY_REPLY)

        for ((action, isReply) in listOf(markRead to false, reply to true)) {
            val pi = shadowOf(action.actionIntent)
            assertTrue("a broadcast, not an activity", pi.isBroadcastIntent)
            val sent = pi.savedIntent
            assertEquals(NotificationActionReceiver::class.java.name, sent.component?.className)
            assertEquals(chat, sent.getStringExtra(NotificationActionReceiver.EXTRA_CONVERSATION))
            assertEquals(TOKEN, sent.getStringExtra(NotificationActionReceiver.EXTRA_TOKEN))
            assertEquals(URL, sent.getStringExtra(NotificationActionReceiver.EXTRA_URL))
            assertEquals(isReply, sent.getBooleanExtra(NotificationActionReceiver.EXTRA_REPLY, !isReply))
        }
        assertTrue(
            "the two buttons are distinct PendingIntents",
            markRead.actionIntent != reply.actionIntent,
        )
    }

    @Test
    fun `Reply requires an unlocked device, Mark as read does not`() {
        arrives()
        val n = posted()
        assertNotNull(n)
        val (markRead, reply) = n.actions!!.toList()
        assertTrue("Reply must require unlock", reply.isAuthenticationRequired)
        assertFalse("Mark as read must not require unlock", markRead.isAuthenticationRequired)
    }

    @Test
    fun `no ticket, an empty token, or a url that is not https get no buttons`() {
        for ((token, url) in listOf(null to URL, "" to URL, TOKEN to null, TOKEN to "http://project.example/x")) {
            manager.cancelAll()
            arrives(token, url)
            val n = posted()
            assertNotNull("still drawn ($token, $url)", n)
            assertTrue("no buttons for ($token, $url)", n.actions.isNullOrEmpty())
        }
    }

    // ---- the receiver ----

    @Test
    fun `the receiver is not exported and intentFor targets it`() {
        val info = app.packageManager.getReceiverInfo(
            ComponentName(app, NotificationActionReceiver::class.java),
            0,
        )
        assertFalse("only SIS's own PendingIntents reach it", info.exported)

        val i = NotificationActionReceiver.intentFor(app, chat, TOKEN, URL, true)
        assertEquals(NotificationActionReceiver::class.java.name, i.component?.className)
        assertEquals(app.packageName, i.component?.packageName)
        assertEquals(chat, i.getStringExtra(NotificationActionReceiver.EXTRA_CONVERSATION))
        assertTrue(i.getBooleanExtra(NotificationActionReceiver.EXTRA_REPLY, false))
    }

    private fun tapReply(url: String, text: String) {
        val intent = NotificationActionReceiver.intentFor(app, chat, TOKEN, url, true)
        RemoteInput.addResultsToIntent(
            arrayOf(RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY).build()),
            intent,
            Bundle().apply { putCharSequence(NotificationActionReceiver.KEY_REPLY, text) },
        )
        app.sendBroadcast(intent)
        ShadowLooper.idleMainLooper()
    }

    /** The receiver works off the main thread (goAsync): wait for the shade to change. */
    private fun waitFor(what: String, check: () -> Boolean) {
        val until = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < until) {
            ShadowLooper.idleMainLooper()
            if (check()) return
            Thread.sleep(25)
        }
        throw AssertionError("timed out waiting for: $what")
    }

    @Test
    fun `a reply that cannot be sent says Not sent on the chat's notification`() {
        arrives()
        assertNotNull(posted())
        tapReply("http://127.0.0.1:9/refused", "on my way")
        waitFor("a Not sent line") {
            posted()?.let { n -> lines(n).any { it.contains("Not sent") } } == true
        }
        assertTrue("logs nothing: ${ShadowLog.getLogs()}", ShadowLog.getLogs().isEmpty())
    }

    @Test
    fun `a reply that cannot be sent keeps the chat in the inbox`() {
        arrives()
        val key = "flutter.sis.push_inbox.member-a"
        tapReply("http://127.0.0.1:9/refused", "on my way")
        waitFor("a Not sent line") {
            posted()?.let { n -> lines(n).any { it.contains("Not sent") } } == true
        }
        assertNotNull(PushInbox.find(PushInbox.parse(prefs.getString(key, null)), chat))
    }

    // ---- L1: below API 31 a Reply is refused while the phone is locked ----

    /**
     * A loopback port that counts the connections made to it. It speaks no TLS, so a post to it
     * fails after connecting -- the count is what shows whether anything was sent.
     */
    private class CountingServer : AutoCloseable {
        private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        val connections = AtomicInteger()
        val url = "https://127.0.0.1:${socket.localPort}/notification-action"

        init {
            thread(isDaemon = true) {
                while (!socket.isClosed) {
                    runCatching { socket.accept().use { connections.incrementAndGet() } }
                }
            }
        }

        override fun close() = socket.close()
    }

    private fun locked(on: Boolean) =
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceLocked(on)

    private fun tapMarkRead(url: String) {
        app.sendBroadcast(NotificationActionReceiver.intentFor(app, chat, TOKEN, url, false))
        ShadowLooper.idleMainLooper()
    }

    private fun notSent() = posted()?.let { n -> lines(n).any { it.contains("Not sent") } } == true

    @Test
    @Config(sdk = [30])
    fun `API 30 locked - a Reply sends nothing and says Not sent`() {
        arrives()
        locked(true)
        CountingServer().use { server ->
            tapReply(server.url, "typed on the lock screen")
            waitFor("a Not sent line") { notSent() }
            Thread.sleep(500) // a request would have connected by now
            assertEquals("connections made", 0, server.connections.get())
        }
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 locked - Mark as read still goes out`() {
        arrives()
        locked(true)
        CountingServer().use { server ->
            tapMarkRead(server.url)
            waitFor("a connection") { server.connections.get() > 0 }
        }
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 unlocked - a Reply goes out`() {
        arrives()
        locked(false)
        CountingServer().use { server ->
            tapReply(server.url, "on my way")
            waitFor("a connection") { server.connections.get() > 0 }
        }
    }

    @Test
    @Config(sdk = [31])
    fun `API 31 locked - a Reply goes out, the unlock was Android's to ask for`() {
        arrives()
        locked(true)
        CountingServer().use { server ->
            tapReply(server.url, "on my way")
            waitFor("a connection") { server.connections.get() > 0 }
        }
    }

    // ---- PushInbox.remove ----

    @Test
    fun `remove drops one chat and keeps the others`() {
        var raw = PushInbox.add(null, "chat-a", "A", "Ann", null, "one", 1L, "m1")
        raw = PushInbox.add(raw, "chat-b", "B", "Bob", null, "two", 2L, "m2")
        val left = PushInbox.remove(raw, "chat-a")
        assertNull(PushInbox.find(PushInbox.parse(left), "chat-a"))
        assertNotNull(PushInbox.find(PushInbox.parse(left), "chat-b"))
        assertEquals(1, PushInbox.parse(left).length())
    }

    @Test
    fun `remove of a missing chat or an empty inbox changes nothing and never throws`() {
        val raw = PushInbox.add(null, "chat-a", "A", "Ann", null, "one", 1L, "m1")
        assertEquals(PushInbox.parse(raw).toString(), PushInbox.parse(PushInbox.remove(raw, "nope")).toString())
        assertEquals(0, PushInbox.parse(PushInbox.remove(null, "chat-a")).length())
        assertEquals(0, PushInbox.parse(PushInbox.remove("not json", "chat-a")).length())
    }
}
