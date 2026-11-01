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
import java.util.UUID
import org.junit.After
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
 * Reaction pushes on Android (design t_a337e6d066, Slice 2 A2/A5/A6, AC-10/11/12/13), written from
 * the contract and the qa interface, not the code. Seam: PeekRunner.override (returns the emoji)
 * and PeekRunner.quotes[message_id] (the quote the Dart peek would hand back).
 */
private val OWNER = "0f0e0d0c-0b0a-4908-8706-050403020100"
private val REACTOR = "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
private val REACTOR_2 = "2b3c4d5e-6f7a-4b2c-9d3e-4f5a6b7c8d9e"
private const val GENERIC = "New reaction to your message"
private const val QUOTE = "See you at 6"
private const val LOCK = "🔒"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ReactionPushDrawTest {
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
        shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).setIsDeviceSecure(false)
        InstantPush.resetPacing()
        peekReturns(null)
    }

    @After
    fun tearDown() {
        PeekRunner.override = null
        PeekRunner.quotes.clear()
    }

    /** The peek answers [emoji] and, like the Dart side, leaves [quote] for the reacted message. */
    private fun peekReturns(emoji: String?, quote: String? = null) {
        PeekRunner.override = { b ->
            asked.add(b)
            if (quote != null) PeekRunner.quotes[b.getString("message_id")!!] = quote
            emoji
        }
    }

    private fun uuid() = UUID.randomUUID().toString()

    /** A private chat's reaction push: no e/q/qk, ciphertext ct/ot (the leak table). */
    private fun privatePush(chat: String, message: String = uuid(), reactor: String = REACTOR, ct: String? = "AwogQmFzZTY0Q2lwaGVydGV4dA==") =
        base(chat, message, reactor).apply {
            putString("encrypted", "true")
            if (ct != null) { putString("ct", ct); putString("ot", "1") }
        }

    /** A plain chat's reaction push: the server sends e, q, qk. */
    private fun plainPush(chat: String, message: String = uuid(), reactor: String = REACTOR, e: String? = "👍", q: String? = null, qk: String? = null) =
        base(chat, message, reactor).apply {
            if (e != null) putString("e", e)
            if (q != null) putString("q", q)
            if (qk != null) putString("qk", qk)
        }

    private fun base(chat: String, message: String, reactor: String) = Bundle().apply {
        putString("user_id", OWNER)
        putString("conversation_id", chat)
        putString("message_id", message)
        putString("kind", "reaction")
        putString("reactor_id", reactor)
        putString("title", "Ann Reactor")
        putString("body", "server generic body")
        putString("google.original_priority", "normal")
        putString("google.delivered_priority", "normal")
    }

    private fun drawn(chat: String): Notification? =
        shadowOf(manager).getNotification(InstantPush.notificationId(chat))

    private fun show(b: Bundle): Notification {
        InstantPush.show(app, b)
        return drawn(b.getString("conversation_id")!!)!!
    }

    private fun lines(n: Notification) =
        NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(n)!!.messages.map { it.text.toString() }

    private fun allPrefs(): String = prefs.all.entries.joinToString("\n") { "${it.key}=${it.value}" }

    // ---- AC-11: private chat text -------------------------------------------------------------

    @Test
    fun `private chat, opened with my message's quote - the line is the emoji and the quote`() {
        peekReturns("👍", QUOTE)
        val n = show(privatePush(uuid()))
        assertEquals(listOf("Reacted 👍 to: \"See you at 6\""), lines(n))
        assertEquals(1, asked.size)
        assertEquals("reaction", asked.single().getString("kind"))
        assertEquals(REACTOR, asked.single().getString("reactor_id"))
    }

    @Test
    fun `private chat, opened but the message is not in the store - Reacted to your message`() {
        peekReturns("👍")
        assertEquals(listOf("Reacted 👍 to your message"), lines(show(privatePush(uuid()))))
    }

    @Test
    fun `private chat, not opened - the generic text and no lock anywhere`() {
        peekReturns(null)
        val n = show(privatePush(uuid()))
        assertEquals(listOf(GENERIC), lines(n))
        assertEquals(1, asked.size)
        assertFalse(n.extras.toString().contains(LOCK))
        assertFalse(allPrefs().contains(LOCK))
    }

    @Test
    fun `private chat without ct - the generic text, the peek is never asked`() {
        peekReturns("👍", QUOTE)
        assertEquals(listOf(GENERIC), lines(show(privatePush(uuid(), ct = null))))
        assertEquals(0, asked.size)
    }

    // ---- AC-12: nothing private at rest ------------------------------------------------------

    @Test
    fun `private chat - the SharedPreferences inbox holds the generic text, never the emoji or the quote`() {
        peekReturns("🦄", "the unicorn plan")
        show(privatePush(uuid()))
        val inbox = prefs.getString("flutter.sis.push_inbox.$OWNER", null)
        assertNotNull("push inbox written", inbox)
        assertTrue(inbox, inbox!!.contains(GENERIC))
        assertFalse(allPrefs(), allPrefs().contains("🦄"))
        assertFalse(allPrefs(), allPrefs().contains("the unicorn plan"))
    }

    // ---- plain chat text from e / q / qk ----------------------------------------------------

    @Test
    fun `plain chat - built on the phone from e, q and qk, the peek never asked`() {
        peekReturns("WRONG")
        assertEquals(listOf("Reacted 👍 to: \"See you at 6\""), lines(show(plainPush(uuid(), q = QUOTE))))
        assertEquals(listOf("Reacted 👍 to your photo"), lines(show(plainPush(uuid(), qk = "photo"))))
        assertEquals(listOf("Reacted 👍 to your message"), lines(show(plainPush(uuid()))))
        assertEquals(listOf(GENERIC), lines(show(plainPush(uuid(), e = null))))
        assertEquals(0, asked.size)
    }

    // ---- AC-10: replace, never stack ---------------------------------------------------------

    @Test
    fun `a changed emoji replaces that reactor's line for that message`() {
        val chat = uuid()
        val message = uuid()
        show(plainPush(chat, message, e = "👍"))
        val n = show(plainPush(chat, message, e = "❤️"))
        assertEquals(listOf("Reacted ❤️ to your message"), lines(n))
    }

    @Test
    fun `a changed emoji in a private chat replaces the line too`() {
        val chat = uuid()
        val message = uuid()
        peekReturns("👍")
        show(privatePush(chat, message))
        peekReturns("😂")
        assertEquals(listOf("Reacted 😂 to your message"), lines(show(privatePush(chat, message))))
    }

    @Test
    fun `a replaced private line whose new peek fails shows the generic text, not the old emoji`() {
        val chat = uuid()
        val message = uuid()
        peekReturns("\uD83D\uDC4D")
        show(privatePush(chat, message))
        peekReturns(null)
        assertEquals(listOf(GENERIC), lines(show(privatePush(chat, message))))
    }

    @Test
    fun `two different reactors on one message give two lines`() {
        val chat = uuid()
        val message = uuid()
        show(plainPush(chat, message, reactor = REACTOR, e = "👍"))
        val n = show(plainPush(chat, message, reactor = REACTOR_2, e = "😂"))
        assertEquals(
            listOf("Reacted 👍 to your message", "Reacted 😂 to your message"),
            lines(n),
        )
    }

    // ---- AC-13 and bad ids: nothing drawn ----------------------------------------------------

    @Test
    fun `my own reaction (reactor_id == user_id) draws nothing`() {
        val chat = uuid()
        assertFalse(InstantPush.show(app, plainPush(chat, reactor = OWNER)))
        assertNull(drawn(chat))
        assertNull(prefs.getString("flutter.sis.push_inbox.$OWNER", null))
    }

    @Test
    fun `my own reaction through the production receiver draws nothing`() {
        val chat = uuid()
        PushArrivalReceiver().onReceive(
            app,
            Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(privatePush(chat, reactor = OWNER)) },
        )
        assertNull(drawn(chat))
        assertEquals(0, asked.size)
    }

    @Test
    fun `a reaction with a missing or malformed reactor_id draws nothing`() {
        for (bad in listOf<String?>(null, "", "not-a-uuid", REACTOR.uppercase(), "$REACTOR:x")) {
            val chat = uuid()
            val b = plainPush(chat).apply { if (bad == null) remove("reactor_id") else putString("reactor_id", bad) }
            assertFalse("reactor_id=$bad", InstantPush.show(app, b))
            assertNull("reactor_id=$bad", drawn(chat))
        }
    }

    @Test
    fun `a reaction with a malformed message_id draws nothing`() {
        val chat = uuid()
        assertFalse(InstantPush.show(app, plainPush(chat, message = "m:1")))
        assertNull(drawn(chat))
    }

    // ---- through the production receiver -----------------------------------------------------

    @Test
    fun `through the production receiver a private reaction shows the peeked emoji`() {
        val chat = uuid()
        peekReturns("👍", QUOTE)
        PushArrivalReceiver().onReceive(
            app,
            Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(privatePush(chat)) },
        )
        assertEquals(listOf("Reacted 👍 to: \"See you at 6\""), lines(drawn(chat)!!))
        assertFalse(allPrefs(), allPrefs().contains(QUOTE))
    }

    // ---- A6 / AC-15: lock screen -------------------------------------------------------------

    @Test
    fun `a reaction is private on the lock screen - SIS and New message, no emoji, no name`() {
        peekReturns("👍", QUOTE)
        val n = show(privatePush(uuid()))
        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility)
        val pub = n.publicVersion!!
        assertEquals("SIS", pub.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
        assertEquals("New message", pub.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
        assertFalse(pub.extras.toString().contains("👍"))
        assertFalse(pub.extras.toString().contains(QUOTE))
        assertFalse(pub.extras.toString().contains("Ann Reactor"))
    }

    // ---- A3: PeekRunner.wanted for a reaction ------------------------------------------------

    @Test
    fun `PeekRunner wanted for a private reaction with ct, not without`() {
        assertTrue(PeekRunner.wanted(privatePush(uuid())))
        assertFalse(PeekRunner.wanted(privatePush(uuid(), ct = null)))
        for (bad in listOf("", "not-a-uuid", REACTOR.uppercase())) {
            assertFalse("reactor_id=$bad", PeekRunner.wanted(privatePush(uuid(), reactor = bad)))
        }
        assertFalse(PeekRunner.wanted(privatePush(uuid()).apply { remove("reactor_id") }))
    }

    // ---- A5: strings EN ------------------------------------------------------------------------

    @Test
    fun `reactionText follows the EN table`() {
        val t = "👍"
        assertEquals("Reacted $t to: \"See you at 6\"", InstantPush.reactionText(app, t, QUOTE, null))
        assertEquals("Reacted $t to your message", InstantPush.reactionText(app, t, null, null))
        assertEquals("Reacted $t to your photo", InstantPush.reactionText(app, t, null, "photo"))
        assertEquals("Reacted $t to your video", InstantPush.reactionText(app, t, null, "video"))
        assertEquals("Reacted $t to your sticker", InstantPush.reactionText(app, t, null, "sticker"))
        assertEquals("Reacted $t to your voice message", InstantPush.reactionText(app, t, null, "voice"))
        assertEquals("Reacted $t to your file", InstantPush.reactionText(app, t, null, "file"))
        assertEquals("Reacted $t to your message", InstantPush.reactionText(app, t, null, "poll"))
        assertEquals(GENERIC, InstantPush.reactionText(app, null, QUOTE, "photo"))
    }

    @Test
    @Config(qualifiers = "tr")
    fun `reactionText follows the TR table`() {
        val t = "👍"
        assertEquals("\"6'da görüşürüz\" mesajınıza $t tepkisini verdi", InstantPush.reactionText(app, t, "6'da görüşürüz", null))
        assertEquals("Mesajınıza $t tepkisini verdi", InstantPush.reactionText(app, t, null, null))
        assertEquals("Fotoğrafınıza $t tepkisini verdi", InstantPush.reactionText(app, t, null, "photo"))
        assertEquals("Videonuza $t tepkisini verdi", InstantPush.reactionText(app, t, null, "video"))
        assertEquals("Çıkartmanıza $t tepkisini verdi", InstantPush.reactionText(app, t, null, "sticker"))
        assertEquals("Sesli mesajınıza $t tepkisini verdi", InstantPush.reactionText(app, t, null, "voice"))
        assertEquals("Dosyanıza $t tepkisini verdi", InstantPush.reactionText(app, t, null, "file"))
        assertEquals("Mesajınıza yeni tepki", InstantPush.reactionText(app, null, null, null))
    }
}
