package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Private Chats 4b G, R1: the engine wait is bounded. Written from the contract, not the code:
 * - one push may use at most ~3 s;
 * - a burst shares a 6 s budget; under 500 ms left => no peek, the push is drawn locked;
 * - the budget is full again after 15 s without a peek.
 * Seams: PeekRunner.now (fake clock), PeekRunner.engine (called after the budget check with the ms
 * this push may use; the time it takes on `now` is charged), PeekRunner.resetBudget().
 * Peeks run on a worker thread, as the draw thread does (peek is null on the main thread).
 */
private const val OWNER = "member-a"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PeekBudgetTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private var clock = 1_000_000L
    private val allowed = mutableListOf<Long>()

    @Before
    fun setUp() {
        PeekRunner.override = null
        PeekRunner.now = { clock }
        PeekRunner.resetBudget()
    }

    @After
    fun tearDown() {
        PeekRunner.engine = null
        PeekRunner.now = { System.currentTimeMillis() }
        PeekRunner.resetBudget()
    }

    /** The engine takes [costMs] on the fake clock and returns "text". */
    private fun engineTakes(costMs: Long) {
        PeekRunner.engine = { _, ms -> allowed.add(ms); clock += costMs; "text" }
    }

    private fun extras(chat: String = "c-budget") = Bundle().apply {
        putString("message_id", java.util.UUID.randomUUID().toString())
        putString("conversation_id", chat)
        putString("title", "Ann Sender")
        putString("body", "server placeholder body")
        putString("sender", "Ann Sender")
        putString("user_id", OWNER)
        putString("encrypted", "true")
        putString("ct", "AwogQmFzZTY0Q2lwaGVydGV4dA==")
        putString("ot", "1")
    }

    private fun <T> offMain(block: () -> T): T {
        var out: Result<T>? = null
        val t = Thread { out = runCatching(block) }
        t.start()
        t.join(10_000)
        return out!!.getOrThrow()
    }

    private fun peek(): String? = offMain { PeekRunner.peek(app, extras()) }

    @Test
    fun `one push may use at most 3 s`() {
        engineTakes(100)
        assertEquals("text", peek())
        assertEquals(listOf(3000L), allowed)
    }

    @Test
    fun `two slow pushes share the 6 s budget`() {
        engineTakes(3000)
        assertEquals("text", peek())
        engineTakes(2000)
        assertEquals("text", peek())
        engineTakes(100)
        assertEquals("text", peek())
        // 3000 + 2000 spent: the third may only use what is left of 6000.
        assertEquals(listOf(3000L, 3000L, 1000L), allowed)
    }

    @Test
    fun `under 500 ms left the engine is not called`() {
        engineTakes(3000)
        peek()
        engineTakes(2600)
        peek()
        engineTakes(100)
        assertNull(peek())
        assertEquals(listOf(3000L, 3000L), allowed)
    }

    @Test
    fun `with the budget used up the push is drawn locked without the engine`() {
        val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
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
        app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit().clear()
            .putString("flutter.sis.push_inbox_owner", OWNER).commit()
        InstantPush.resetPacing()
        PeekRunner.engine = { _, ms -> allowed.add(ms); clock += 3000; "secret one" }
        offMain { InstantPush.show(app, extras("c-b1"), paced = false) }
        offMain { InstantPush.show(app, extras("c-b2"), paced = false) }
        fun line(chat: String) = NotificationCompat.MessagingStyle
            .extractMessagingStyleFromNotification(shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!)!!
            .messages.last().text.toString()
        assertEquals("secret one", line("c-b2"))
        offMain { InstantPush.show(app, extras("c-b3"), paced = false) }
        assertEquals(2, allowed.size)
        assertEquals("🔒 New message", line("c-b3"))
    }

    @Test
    fun `the budget is full again after 15 s without a peek`() {
        engineTakes(3000)
        peek()
        peek()
        engineTakes(100)
        clock += 15_500
        assertEquals("text", peek())
        assertEquals(listOf(3000L, 3000L, 3000L), allowed)
    }

    @Test
    fun `after only 14 s without a peek the budget is still used up`() {
        engineTakes(3000)
        peek()
        peek()
        engineTakes(100)
        clock += 14_000
        assertNull(peek())
        assertEquals(listOf(3000L, 3000L), allowed)
    }
}
