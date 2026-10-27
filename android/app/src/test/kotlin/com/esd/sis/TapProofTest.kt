package com.esd.sis

import android.app.Application
import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.io.File

/**
 * Only SIS's own notification taps open a chat. Written from the contract, not the code:
 * - stamp then admit keeps the SELECT_NOTIFICATION action and the payload, and removes the proof;
 * - no proof, or a wrong one, clears the SELECT_NOTIFICATION action;
 * - intents with any other action are untouched;
 * - the per-install secret is stable, 64 hex chars, never logged, and regenerated when app data is cleared;
 * - InstantPush.tapIntent's PendingIntent carries the proof.
 * The proof extra's name is not part of the contract: it is found as "the extra stamp added".
 */
private const val SELECT = "SELECT_NOTIFICATION"
private val HEX64 = Regex("^[0-9a-f]{64}$", RegexOption.IGNORE_CASE)

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TapProofTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    private fun tap(chat: String = "c-tp-1") = Intent(app, MainActivity::class.java)
        .setAction(SELECT)
        .putExtra("payload", chat)
        .putExtra("notificationId", 42)

    private fun keys(i: Intent): Set<String> = i.extras?.keySet()?.toSet() ?: emptySet()

    /** The extras stamp added to a fresh tap intent: exactly the proof. */
    private fun proofOf(stamped: Intent): Pair<String, String> {
        val added = keys(stamped) - keys(tap())
        assertEquals("stamp adds exactly one extra: $added", 1, added.size)
        val name = added.single()
        return name to stamped.extras!!.get(name).toString()
    }

    /** What clearing app data does to stored state: every shared-preferences file gone. */
    private fun clearAppData() {
        val dir = File(app.dataDir, "shared_prefs")
        dir.listFiles()?.forEach { app.deleteSharedPreferences(it.name.removeSuffix(".xml")) }
    }

    @Test
    fun `stamp then admit keeps the action and payload and removes the proof`() {
        val i = TapProof.stamp(app, tap("c-tp-ok"))
        proofOf(i)
        TapProof.admit(app, i)
        assertEquals(SELECT, i.action)
        assertEquals("c-tp-ok", i.getStringExtra("payload"))
        assertEquals(42, i.getIntExtra("notificationId", -1))
        assertEquals("proof extra removed", keys(tap()), keys(i))
    }

    @Test
    fun `a tap intent without a proof loses its action`() {
        val i = tap("c-tp-foreign")
        TapProof.admit(app, i)
        assertNull(i.action)
    }

    @Test
    fun `a tap intent with a wrong proof loses its action`() {
        val (name, good) = proofOf(TapProof.stamp(app, tap()))
        for (wrong in listOf("0".repeat(64), "", good.dropLast(1), good.uppercase().reversed())) {
            if (wrong == good) continue
            val i = tap("c-tp-forged").putExtra(name, wrong)
            TapProof.admit(app, i)
            assertNull("forged proof '$wrong' admitted", i.action)
        }
    }

    @Test
    fun `other intents are untouched`() {
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        TapProof.admit(app, main)
        assertEquals(Intent.ACTION_MAIN, main.action)

        val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "hi")
        TapProof.admit(app, share)
        assertEquals(Intent.ACTION_SEND, share.action)
        assertEquals("hi", share.getStringExtra(Intent.EXTRA_TEXT))

        TapProof.admit(app, null)
    }

    @Test
    fun `the secret is stable, 64 hex chars, and never logged`() {
        ShadowLog.clear()
        val (_, a) = proofOf(TapProof.stamp(app, tap()))
        val (_, b) = proofOf(TapProof.stamp(app, tap("c-tp-other")))
        assertEquals("same proof across calls", a, b)
        assertTrue("64 hex chars: $a", HEX64.matches(a))
        val forged = tap()
        TapProof.admit(app, forged)
        TapProof.admit(app, TapProof.stamp(app, tap()))
        assertFalse("secret logged", ShadowLog.getLogs().any { it.msg?.contains(a) == true })
    }

    @Test
    fun `clearing app data regenerates the secret, and an old tap then opens no chat`() {
        val old = TapProof.stamp(app, tap("c-tp-old"))
        val (_, before) = proofOf(old)
        clearAppData()
        val (_, after) = proofOf(TapProof.stamp(app, tap()))
        assertNotEquals("secret regenerated", before, after)
        TapProof.admit(app, old)
        assertNull("old notification no longer opens a chat", old.action)
    }

    @Test
    fun `InstantPush tapIntent carries the proof`() {
        val pi = InstantPush.tapIntent(app, 7, "c-tp-native")
        assertNotNull(pi)
        val shadow = shadowOf(pi)
        assertTrue(shadow.isActivityIntent)
        val sent = Intent(shadow.savedIntent)
        assertEquals(SELECT, sent.action)
        assertEquals(MainActivity::class.java.name, sent.component?.className)
        TapProof.admit(app, sent)
        assertEquals("our own tap admitted", SELECT, sent.action)
        assertEquals("c-tp-native", sent.getStringExtra("payload"))
    }

    @Test
    fun `a SELECT_FOREGROUND_NOTIFICATION without a proof loses its tap action`() {
        // flutter_local_notifications reads this action as a tap too; SIS never builds one.
        for (proof in listOf<String?>(null, "0".repeat(64))) {
            val i = tap("c-tp-fg").setAction("SELECT_FOREGROUND_NOTIFICATION")
            if (proof != null) i.putExtra(proofOf(TapProof.stamp(app, tap())).first, proof)
            TapProof.admit(app, i)
            assertFalse("still a plugin tap: ${i.action}", i.action in setOf(SELECT, "SELECT_FOREGROUND_NOTIFICATION"))
        }
    }
}
