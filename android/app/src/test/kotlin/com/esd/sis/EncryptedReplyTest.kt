package com.esd.sis

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.UUID

/**
 * Private Chats 4b Group I: Reply on an encrypted push. Written from the contract, not the code:
 * - an encrypted push with a user_id gets exactly one Reply (no Mark as read): SEMANTIC_ACTION_REPLY,
 *   RemoteInput "sis_reply", needs an unlock, shows UI; its PendingIntent is an activity one, the only
 *   mutable one on the notification, aimed at EncryptedReplyActivity with conversation_id + user_id;
 * - no Reply without a user_id, or on API 30 behind a secure lock;
 * - EncryptedReplyActivity hands the trimmed text to EncryptedReplyInbox (memory only) under an id made
 *   at that tap, clears its extras, cancels the notification, opens MainActivity on the chat;
 *   anything missing, blank or over 4000 chars: nothing stored, nothing opened;
 * - below API 31 on a locked phone (isDeviceLocked) the activity stores nothing and opens nothing;
 *   from API 31 the lock does not block it (the system asks for the unlock);
 * - EncryptedReplyInbox keeps at most 20 (oldest dropped) and take() empties it.
 * Drives the activity with the intent the drawn notification really carries (the seam).
 */
private const val OWNER = "member-a"
private const val SECRET = "see you at the old bridge"
private val UUID_RE = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EncryptedReplyTest {
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
        secureLock(false)
        locked(false)
        InstantPush.resetPacing()
        EncryptedReplyInbox.take()
    }

    private fun secureLock(on: Boolean) =
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(on)

    private fun locked(on: Boolean) =
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceLocked(on)

    private fun draw(chat: String, encrypted: String? = "true", user: String? = OWNER): Notification {
        val b = Bundle().apply {
            putString("message_id", "00000000-0000-4000-8000-%012d".format(++seq))
            putString("conversation_id", chat)
            putString("title", "Ann Sender")
            putString("body", "server placeholder body")
            putString("sender", "Ann Sender")
            putString("chat", "Ann Sender")
            if (user != null) putString("user_id", user)
            putString("google.original_priority", "normal")
            putString("google.delivered_priority", "normal")
            putString("action_token", "v1.ticket-for-chat.sig")
            putString("action_url", "https://project.example/functions/v1/notification-action")
            if (encrypted != null) putString("encrypted", encrypted)
        }
        PushArrivalReceiver().onReceive(app, Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(b) })
        return shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!
    }

    private fun titles(n: Notification) = n.actions.orEmpty().map { it.title.toString() }

    /** The intent the Reply button would start, with [text] typed into it as the system does. */
    private fun replyIntent(n: Notification, text: String): Intent {
        val saved = shadowOf(n.actions.single().actionIntent).savedIntent
        val intent = Intent(saved)
        RemoteInput.addResultsToIntent(
            arrayOf(RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY).build()),
            intent,
            Bundle().apply { putCharSequence(NotificationActionReceiver.KEY_REPLY, text) },
        )
        return intent
    }

    private fun launch(intent: Intent): Activity =
        Robolectric.buildActivity(EncryptedReplyActivity::class.java, intent).create().get()

    /** A reply intent built by hand, for the guard cases. */
    private fun handIntent(conv: String?, user: String?, text: String?): Intent {
        val intent = Intent(app, EncryptedReplyActivity::class.java)
        if (conv != null) intent.putExtra(EncryptedReplyActivity.EXTRA_CONVERSATION, conv)
        if (user != null) intent.putExtra(EncryptedReplyActivity.EXTRA_USER, user)
        if (text != null) {
            RemoteInput.addResultsToIntent(
                arrayOf(RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY).build()),
                intent,
                Bundle().apply { putCharSequence(NotificationActionReceiver.KEY_REPLY, text) },
            )
        }
        return intent
    }

    // ---- the button ----

    @Test
    fun `an encrypted push has one Reply that goes to EncryptedReplyActivity`() {
        val n = draw("c-er-1")
        assertEquals(listOf("Reply"), titles(n))
        val compat = NotificationCompat.getAction(n, 0)!!
        assertEquals(NotificationCompat.Action.SEMANTIC_ACTION_REPLY, compat.semanticAction)
        assertTrue("opens UI", compat.showsUserInterface)
        assertEquals(listOf(NotificationActionReceiver.KEY_REPLY), n.actions[0].remoteInputs.map { it.resultKey })
        assertTrue("Reply needs an unlock", n.actions[0].isAuthenticationRequired)

        val pi = shadowOf(n.actions[0].actionIntent)
        assertTrue("an activity PendingIntent", pi.isActivityIntent)
        val sent = pi.savedIntent
        assertEquals(EncryptedReplyActivity::class.java.name, sent.component?.className)
        assertEquals(app.packageName, sent.component?.packageName)
        assertEquals("c-er-1", sent.getStringExtra(EncryptedReplyActivity.EXTRA_CONVERSATION))
        assertEquals(OWNER, sent.getStringExtra(EncryptedReplyActivity.EXTRA_USER))
        assertEquals("sis-action://encrypted-reply/c-er-1", sent.dataString)
        // No id, text or token rides in the button: the id is made at the tap.
        assertEquals(setOf("conversation_id", "user_id"), sent.extras!!.keySet())
    }

    @Test
    fun `FLAG_MUTABLE is on the encrypted Reply only, never on the tap intent`() {
        val n = draw("c-er-flags")
        val reply = shadowOf(n.actions.single().actionIntent).flags
        assertTrue("Reply is mutable (RemoteInput)", reply and PendingIntent.FLAG_MUTABLE != 0)
        assertTrue("Reply is UPDATE_CURRENT", reply and PendingIntent.FLAG_UPDATE_CURRENT != 0)
        val tap = shadowOf(n.contentIntent).flags
        assertEquals("the tap intent stays immutable", 0, tap and PendingIntent.FLAG_MUTABLE)
        assertTrue(tap and PendingIntent.FLAG_IMMUTABLE != 0)
    }

    @Test
    fun `no user_id - no Reply on an encrypted push`() =
        assertEquals(emptyList<String>(), titles(draw("c-er-nouser", user = null)))

    @Test
    @Config(sdk = [30])
    fun `API 30 behind a secure lock - no Reply on an encrypted push`() {
        secureLock(true)
        assertEquals(emptyList<String>(), titles(draw("c-er-30s")))
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 with no secure lock - Reply on an encrypted push`() {
        secureLock(false)
        assertEquals(listOf("Reply"), titles(draw("c-er-30o")))
    }

    @Test
    @Config(sdk = [31])
    fun `API 31 behind a secure lock - Reply offered behind an unlock`() {
        secureLock(true)
        val n = draw("c-er-31s")
        assertEquals(listOf("Reply"), titles(n))
        assertTrue(n.actions[0].isAuthenticationRequired)
    }

    @Test
    fun `a plain push keeps Mark as read and Reply as broadcasts`() {
        val n = draw("c-er-plain", encrypted = null)
        assertEquals(listOf("Mark as read", "Reply"), titles(n))
        for (a in n.actions) assertTrue(shadowOf(a.actionIntent).isBroadcastIntent)
    }

    // ---- the activity ----

    @Test
    fun `a Reply tap puts the trimmed text in the inbox once, under a fresh uuid`() {
        val a = launch(replyIntent(draw("c-er-2"), "  $SECRET \n"))
        val got = EncryptedReplyInbox.take()
        assertEquals(1, got.size)
        val r = got.single()
        assertEquals(setOf("id", "conversation_id", "user_id", "text"), r.keys)
        assertEquals("c-er-2", r["conversation_id"])
        assertEquals(OWNER, r["user_id"])
        assertEquals(SECRET, r["text"])
        assertTrue("a uuid: ${r["id"]}", UUID_RE.matches(r["id"]!!.lowercase()))
        assertTrue("finished", a.isFinishing)
        assertEquals(emptyList<Map<String, String>>(), EncryptedReplyInbox.take())
    }

    @Test
    fun `the id is made at the tap - the same button tapped twice gives two ids`() {
        val n = draw("c-er-3")
        launch(replyIntent(n, "one"))
        launch(replyIntent(n, "two"))
        val got = EncryptedReplyInbox.take()
        assertEquals(listOf("one", "two"), got.map { it["text"] })
        assertNotEquals(got[0]["id"], got[1]["id"])
    }

    @Test
    fun `the activity clears its intent extras after reading`() {
        val sent = replyIntent(draw("c-er-4"), SECRET)
        val a = launch(sent)
        for ((which, left) in listOf("activity intent" to a.intent.extras, "launch intent" to sent.extras)) {
            assertTrue("$which extras left: $left", left == null || left.isEmpty)
        }
        assertEquals(1, EncryptedReplyInbox.take().size)
    }

    @Test
    fun `the activity cancels the notification and opens MainActivity on the chat`() {
        val chat = "c-er-5"
        val n = draw(chat)
        assertNotNull(shadowOf(manager).getNotification(InstantPush.notificationId(chat)))
        val a = launch(replyIntent(n, SECRET))
        assertNull("notification cancelled", shadowOf(manager).getNotification(InstantPush.notificationId(chat)))
        val started = shadowOf(a).nextStartedActivity
        assertNotNull("MainActivity started", started)
        assertEquals(MainActivity::class.java.name, started.component?.className)
        assertEquals(app.packageName, started.component?.packageName)
        assertEquals("SELECT_NOTIFICATION", started.action)
        assertEquals(InstantPush.notificationId(chat), started.getIntExtra("notificationId", -1))
        assertEquals(chat, started.getStringExtra("payload"))
        assertFalse("the text never rides to MainActivity", started.extras.toString().contains(SECRET))
    }

    @Test
    fun `the reply text is kept in memory only, never on disk`() {
        launch(replyIntent(draw("c-er-6"), SECRET))
        val disk = app.dataDir.walkTopDown().filter(File::isFile)
            .filter { it.readBytes().toString(Charsets.UTF_8).contains(SECRET) }.toList()
        assertEquals("files holding the text: $disk", emptyList<File>(), disk)
        assertFalse(prefs.all.toString().contains(SECRET))
        assertEquals(SECRET, EncryptedReplyInbox.take().single()["text"])
    }

    @Test
    fun `missing or blank conversation, user or text, or text over 4000 - nothing stored, nothing opened`() {
        val cases = mapOf(
            "no conversation" to handIntent(null, OWNER, SECRET),
            "blank conversation" to handIntent("  ", OWNER, SECRET),
            "no user" to handIntent("c-er-7", null, SECRET),
            "blank user" to handIntent("c-er-7", " ", SECRET),
            "no text" to handIntent("c-er-7", OWNER, null),
            "blank text" to handIntent("c-er-7", OWNER, "   \n"),
            "4001 chars" to handIntent("c-er-7", OWNER, "a".repeat(4001)),
        )
        for ((why, intent) in cases) {
            val a = launch(intent)
            assertEquals(why, emptyList<Map<String, String>>(), EncryptedReplyInbox.take())
            assertNull("$why: nothing started", shadowOf(a).nextStartedActivity)
            assertTrue("$why: finished", a.isFinishing)
        }
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 on a locked phone - a Reply tap stores nothing and opens nothing`() {
        locked(true)
        val chat = "c-er-30lock"
        val a = launch(handIntent(chat, OWNER, SECRET))
        assertEquals(emptyList<Map<String, String>>(), EncryptedReplyInbox.take())
        assertNull("nothing started", shadowOf(a).nextStartedActivity)
        assertTrue("finished", a.isFinishing)
    }

    @Test
    @Config(sdk = [30])
    fun `API 30 unlocked - a Reply tap is stored and opens the chat`() {
        locked(false)
        val a = launch(handIntent("c-er-30open", OWNER, SECRET))
        assertEquals(SECRET, EncryptedReplyInbox.take().single()["text"])
        assertEquals(MainActivity::class.java.name, shadowOf(a).nextStartedActivity?.component?.className)
    }

    @Test
    @Config(sdk = [31])
    fun `API 31 on a locked phone - the lock does not block the Reply (system auth handles it)`() {
        locked(true)
        val a = launch(handIntent("c-er-31lock", OWNER, SECRET))
        assertEquals(SECRET, EncryptedReplyInbox.take().single()["text"])
        assertEquals(MainActivity::class.java.name, shadowOf(a).nextStartedActivity?.component?.className)
    }

    @Test
    fun `exactly 4000 chars is accepted`() {
        launch(handIntent("c-er-8", OWNER, "b".repeat(4000)))
        assertEquals(4000, EncryptedReplyInbox.take().single()["text"]!!.length)
    }

    @Test
    fun `manifest - EncryptedReplyActivity is not exported, no history, not in recents`() {
        val info = app.packageManager.getActivityInfo(ComponentName(app, EncryptedReplyActivity::class.java), 0)
        assertFalse("exported=false", info.exported)
        assertTrue("noHistory", info.flags and ActivityInfo.FLAG_NO_HISTORY != 0)
        assertTrue("excludeFromRecents", info.flags and ActivityInfo.FLAG_EXCLUDE_FROM_RECENTS != 0)
    }

    // ---- the inbox ----

    @Test
    fun `the inbox keeps the newest 20 in order and take empties it`() {
        for (i in 1..25) EncryptedReplyInbox.add(EncryptedReply(UUID.randomUUID().toString(), "c", OWNER, "t$i"))
        val got = EncryptedReplyInbox.take()
        assertEquals((6..25).map { "t$it" }, got.map { it["text"] })
        assertEquals(emptyList<Map<String, String>>(), EncryptedReplyInbox.take())
    }

    @Test
    fun `take maps every field under its key`() {
        val id = UUID.randomUUID().toString()
        EncryptedReplyInbox.add(EncryptedReply(id, "c-map", OWNER, "hi"))
        assertEquals(
            listOf(mapOf("id" to id, "conversation_id" to "c-map", "user_id" to OWNER, "text" to "hi")),
            EncryptedReplyInbox.take(),
        )
    }
}
