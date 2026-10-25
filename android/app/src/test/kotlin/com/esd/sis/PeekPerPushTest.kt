package com.esd.sis

import android.app.Application
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * t_5d6bdca09e: the reason code (and the peer name) of a peek travels with its own push. Written
 * from the contract, not the code: takeReason(messageId) / takeName(messageId) return what the
 * peek() of the push with that message_id left, once; a second take, or an id never peeked, is
 * null. Seam: PeekRunner.engine (a non-empty text => "ok", null => "other:seam").
 * The name has no JVM seam (it only comes back from the Flutter engine), so for takeName only the
 * "nothing left" side is covered here.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PeekPerPushTest {
    private val app: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        PeekRunner.override = null
        PeekRunner.resetBudget()
    }

    @After
    fun tearDown() {
        PeekRunner.engine = null
        PeekRunner.resetBudget()
        for (id in listOf("A", "B")) {
            PeekRunner.takeReason(id)
            PeekRunner.takeName(id)
        }
    }

    private fun push(id: String) = Bundle().apply {
        putString("message_id", id)
        putString("conversation_id", "c-per-push")
        putString("user_id", "member-b")
        putString("encrypted", "true")
        putString("ct", "AwogQmFzZTY0Q2lwaGVydGV4dA==")
        putString("ot", "1")
    }

    /** A's engine call waits until B's whole peek is done, so A's outcome lands after B's. */
    private fun overlap(): Pair<String?, String?> {
        val bDone = CountDownLatch(1)
        val aInside = CountDownLatch(1)
        PeekRunner.engine = { extras, _ ->
            when (extras.getString("message_id")) {
                "A" -> { aInside.countDown(); bDone.await(2, TimeUnit.SECONDS); "text of A" }
                else -> null
            }
        }
        var a: String? = null
        var b: String? = "unset"
        val ta = Thread { a = PeekRunner.peek(app, push("A")) }
        ta.start()
        aInside.await(5, TimeUnit.SECONDS)
        val tb = Thread { b = PeekRunner.peek(app, push("B")); bDone.countDown() }
        tb.start()
        tb.join(10_000)
        ta.join(10_000)
        return a to b
    }

    @Test
    fun `two overlapping pushes each keep their own reason, read B first`() {
        val (a, b) = overlap()
        assertEquals("text of A", a)
        assertNull(b)
        assertEquals("other:seam", PeekRunner.takeReason("B"))
        assertEquals("ok", PeekRunner.takeReason("A"))
    }

    @Test
    fun `two overlapping pushes each keep their own reason, read A first`() {
        overlap()
        assertEquals("ok", PeekRunner.takeReason("A"))
        assertEquals("other:seam", PeekRunner.takeReason("B"))
    }

    @Test
    fun `a reason is taken once`() {
        overlap()
        assertEquals("ok", PeekRunner.takeReason("A"))
        assertNull(PeekRunner.takeReason("A"))
        assertEquals("other:seam", PeekRunner.takeReason("B"))
        assertNull(PeekRunner.takeReason("B"))
    }

    @Test
    fun `an id that was never peeked has no reason and no name`() {
        overlap()
        assertNull(PeekRunner.takeReason("never-peeked"))
        assertNull(PeekRunner.takeName("never-peeked"))
    }

    @Test
    fun `a seam peek leaves no name for its push`() {
        overlap()
        assertNull(PeekRunner.takeName("A"))
        assertNull(PeekRunner.takeName("B"))
    }
}
