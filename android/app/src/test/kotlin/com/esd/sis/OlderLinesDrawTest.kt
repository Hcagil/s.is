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
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * t_a7085eeee6 rules A5/A6, written from the contract, not the code:
 * - A6: a picture redraw (show(redraw = true)) starts no engine; it draws from memory only.
 * - A5: when the peek does not run (budget spent), every line of the chat stays locked and no
 *   engine starts.
 * Seams: PeekRunner.engine / now / resetBudget (as PeekBudgetTest). The older-line text itself
 * only comes back from the real Flutter engine (no JVM seam): that part is a device row (A-1).
 */
private const val OWNER = "member-a"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OlderLinesDrawTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var clock = 1_000_000L
    private var calls = 0

    @Before
    fun setUp() {
        PeekRunner.override = null
        PeekRunner.now = { clock }
        PeekRunner.resetBudget()
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
    }

    @After
    fun tearDown() {
        PeekRunner.engine = null
        PeekRunner.now = { System.currentTimeMillis() }
        PeekRunner.resetBudget()
    }

    private fun engine(text: String?, costMs: Long = 100) {
        PeekRunner.engine = { _, _ -> calls++; clock += costMs; text }
    }

    private fun extras(chat: String) = Bundle().apply {
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

    private fun lines(chat: String): List<String> = NotificationCompat.MessagingStyle
        .extractMessagingStyleFromNotification(shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!)!!
        .messages.map { it.text.toString() }

    @Test
    fun `A6 a picture redraw starts no engine and keeps the peeked text from memory`() {
        engine("secret one")
        val e = extras("c-a6")
        offMain { InstantPush.show(app, e, paced = false) }
        assertEquals(1, calls)
        assertEquals(listOf("secret one"), lines("c-a6"))
        offMain { InstantPush.show(app, e, paced = false, redraw = true) }
        assertEquals("the redraw started an engine", 1, calls)
        assertEquals(listOf("secret one"), lines("c-a6"))
    }

    @Test
    fun `A5 with the budget spent the new push starts no engine and every line stays locked`() {
        engine(null, costMs = 6000) // the first peek fails and uses the whole burst budget
        offMain { InstantPush.show(app, extras("c-a5"), paced = false) }
        assertEquals(1, calls)
        engine("must not show")
        offMain { InstantPush.show(app, extras("c-a5"), paced = false) }
        assertEquals("no engine once the budget is spent", 1, calls)
        assertEquals(listOf("🔒 New message", "🔒 New message"), lines("c-a5"))
    }
}
