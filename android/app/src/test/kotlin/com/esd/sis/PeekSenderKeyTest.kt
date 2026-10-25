package com.esd.sis

import android.os.Bundle
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Fix C (first private message): a pre-key push may carry `sk` (the sender's identity key) and
 * `si` (the sender's id). Written from the contract, not the code: `PeekRunner.wanted` is
 * unchanged (ct is still required), so sk/si alone never start a peek. The 'take' map itself has
 * no JVM seam (it is built inside peek() after the `engine` seam), so it is not tested here.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PeekSenderKeyTest {
    private var engineCalls = 0

    @Before
    fun setUp() {
        PeekRunner.override = null
        PeekRunner.resetBudget()
        PeekRunner.engine = { _, _ -> engineCalls++; "text" }
        PeekRunner.takeReason("m-sk-1")
    }

    @After
    fun tearDown() {
        PeekRunner.engine = null
        PeekRunner.resetBudget()
    }

    private fun push(ct: String? = "AwogQmFzZTY0Q2lwaGVydGV4dA==", ot: String? = "0") = Bundle().apply {
        putString("message_id", "m-sk-1")
        putString("conversation_id", "c-sk")
        putString("user_id", "member-b")
        putString("encrypted", "true")
        ct?.let { putString("ct", it) }
        ot?.let { putString("ot", it) }
        putString("sk", "A".repeat(43))
        putString("si", "0000a11c-0000-4000-8000-000000000001")
    }

    private fun <T> offMain(block: () -> T): T {
        var out: Result<T>? = null
        val t = Thread { out = runCatching(block) }
        t.start()
        t.join(10_000)
        return out!!.getOrThrow()
    }

    @Test
    fun `a pre-key push with ct, ot 0, sk and si is wanted`() {
        assertTrue(PeekRunner.wanted(push()))
    }

    @Test
    fun `sk and si without ct are not wanted`() {
        assertFalse(PeekRunner.wanted(push(ct = null)))
        assertFalse(PeekRunner.wanted(push(ct = "")))
    }

    @Test
    fun `sk and si without ot are not wanted`() {
        assertFalse(PeekRunner.wanted(push(ot = null)))
    }

    @Test
    fun `a push with sk and si but no ct never reaches the engine and says not_wanted`() {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.app.Application>()
        assertNull(offMain { PeekRunner.peek(app, push(ct = null)) })
        assertEquals(0, engineCalls)
        assertEquals("not_wanted", PeekRunner.takeReason("m-sk-1"))
    }

    @Test
    fun `with ct the same push reaches the engine`() {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.app.Application>()
        assertEquals("text", offMain { PeekRunner.peek(app, push()) })
        assertEquals(1, engineCalls)
        assertEquals("ok", PeekRunner.takeReason("m-sk-1"))
    }
}
