package com.esd.sis

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Unit tests for InstantPush.withPushAlert and alertChannelId.
 * Each test follows the contract described in the task.
 */
class InstantPushAlertTest {

    @Test
    fun `push 1 and 1 turn sound and vibration on over stored off`() {
        val stored = InstantPush.Alert(false, null, false)
        val result = InstantPush.withPushAlert(stored, "1", "1")
        assertEquals(InstantPush.Alert(true, null, true), result)
        assertEquals("msg-sys-v1", InstantPush.alertChannelId(result))
    }

    @Test
    fun `push 0 and 0 turn both off and drop the tone`() {
        val stored = InstantPush.Alert(true, "content://t/1", true)
        val result = InstantPush.withPushAlert(stored, "0", "0")
        assertEquals(InstantPush.Alert(false, null, false), result)
        assertEquals("msg-off-v0", InstantPush.alertChannelId(result))
    }

    @Test
    fun `null push values keep the stored alert`() {
        val stored = InstantPush.Alert(true, "content://t/1", false)
        val result = InstantPush.withPushAlert(stored, null, null)
        assertEquals(stored, result)
    }

    @Test
    fun `unknown push values keep the stored alert`() {
        val stored = InstantPush.Alert(true, "content://t/1", false)
        val result1 = InstantPush.withPushAlert(stored, "x", "")
        assertEquals(stored, result1)
        val result2 = InstantPush.withPushAlert(stored, "yes", "2")
        assertEquals(stored, result2)
    }

    @Test
    fun `push sound 1 keeps the stored tone`() {
        val stored = InstantPush.Alert(true, "content://t/1", true)
        val result = InstantPush.withPushAlert(stored, "1", null)
        assertEquals(InstantPush.Alert(true, "content://t/1", true), result)
    }

    @Test
    fun `push vibration 0 turns only vibration off`() {
        val stored = InstantPush.Alert(true, null, true)
        val result = InstantPush.withPushAlert(stored, "1", "0")
        assertEquals(InstantPush.Alert(true, null, false), result)
        assertEquals("msg-sys-v0", InstantPush.alertChannelId(result))
    }

    @Test
    fun `push sound 0 with null vibration drops tone and keeps vibration`() {
        val stored = InstantPush.Alert(true, "content://t/1", true)
        val result = InstantPush.withPushAlert(stored, "0", null)
        assertEquals(InstantPush.Alert(false, null, true), result)
        assertEquals("msg-off-v1", InstantPush.alertChannelId(result))
    }

    @Test
    fun `null or unknown push sound keeps a stored off sound`() {
        val stored = InstantPush.Alert(false, null, true)
        val a = InstantPush.withPushAlert(stored, null, "x")
        assertEquals(stored, a)
        assertEquals("msg-off-v1", InstantPush.alertChannelId(a))
        val b = InstantPush.withPushAlert(stored, "x", null)
        assertEquals(stored, b)
    }
}
