package com.esd.sis

import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject
import java.io.File

/**
 * The native draw's sound, vibration and channel per chat, from the 0.30.7 contract
 * (docs/DECISIONS.md). Drafted by gpt-oss (test_writer) from the interface only, then corrected.
 * The vectors are shared with the Dart side (instant_push_parity_test.dart), which holds
 * resolveAlert to the same sound/vibration values.
 */
class InstantPushChannelTest {

    @Test
    fun `channelFor maps each sound and vibration pair to its own fixed channel`() {
        assertEquals(InstantPush.CHANNEL_BOTH, InstantPush.channelFor(true, true))
        assertEquals(InstantPush.CHANNEL_SOUND, InstantPush.channelFor(true, false))
        assertEquals(InstantPush.CHANNEL_VIBRATE, InstantPush.channelFor(false, true))
        assertEquals(InstantPush.CHANNEL_QUIET, InstantPush.channelFor(false, false))
        assertEquals("sis-instant", InstantPush.CHANNEL_BOTH)
        assertEquals("sis-instant-sound", InstantPush.CHANNEL_SOUND)
        assertEquals("sis-instant-vibrate", InstantPush.CHANNEL_VIBRATE)
        assertEquals("sis-instant-quiet", InstantPush.CHANNEL_QUIET)
        assertNotEquals(InstantPush.CHANNEL_BOTH, InstantPush.CHANNEL_SOUND)
        assertNotEquals(InstantPush.CHANNEL_BOTH, InstantPush.CHANNEL_VIBRATE)
        assertNotEquals(InstantPush.CHANNEL_BOTH, InstantPush.CHANNEL_QUIET)
        assertNotEquals(InstantPush.CHANNEL_SOUND, InstantPush.CHANNEL_VIBRATE)
        assertNotEquals(InstantPush.CHANNEL_SOUND, InstantPush.CHANNEL_QUIET)
        assertNotEquals(InstantPush.CHANNEL_VIBRATE, InstantPush.CHANNEL_QUIET)
    }

    @Test
    fun `sound, vibration and channel follow the shared vectors`() {
        val file = File("../../test/fixtures/instant_push_vectors.json")
        assertTrue(file.exists())
        val jsonArray = JSONObject(file.readText()).getJSONArray("alerts")
        assertTrue(jsonArray.length() > 0)
        val mismatches = mutableListOf<String>()
        for (i in 0 until jsonArray.length()) {
            val v = jsonArray.getJSONObject(i)
            val name = v.getString("name")
            val defaultsJson = if (v.isNull("defaults")) null else v.getString("defaults")
            val chatsJson = if (v.isNull("chats")) null else v.getString("chats")
            val conversationId = v.getString("conversation_id")
            val expectedSound = v.getBoolean("sound")
            val expectedVibration = v.getBoolean("vibration")
            val expectedChannel = v.getString("channel")
            val actualSound = InstantPush.alerts(defaultsJson, chatsJson, conversationId)
            if (actualSound != expectedSound) mismatches.add("$name: alerts mismatch")
            val actualVibration = InstantPush.vibrates(defaultsJson, chatsJson, conversationId)
            if (actualVibration != expectedVibration) mismatches.add("$name: vibrates mismatch")
            val actualChannel = InstantPush.channelFor(actualSound, actualVibration)
            if (actualChannel != expectedChannel) mismatches.add("$name: channel mismatch")
        }
        assertEquals(emptyList<String>(), mismatches)
    }

    @Test
    fun `a chat override of sound on and vibration off over defaults off is the sound-only channel`() {
        val defaults = """{"s":false,"v":false}"""
        val chats = """{"conv1":{"s":"on","v":"off"}}"""
        val conv = "conv1"
        assertTrue(InstantPush.alerts(defaults, chats, conv))
        assertFalse(InstantPush.vibrates(defaults, chats, conv))
        assertEquals(InstantPush.CHANNEL_SOUND, InstantPush.channelFor(InstantPush.alerts(defaults, chats, conv), InstantPush.vibrates(defaults, chats, conv)))
    }

    @Test
    fun `another chat's override does not touch this chat`() {
        val defaults = """{"s":false,"v":false}"""
        val chats = """{"conv1":{"s":"on","v":"off"}}"""
        val conv = "conv2"
        assertFalse(InstantPush.alerts(defaults, chats, conv))
        assertFalse(InstantPush.vibrates(defaults, chats, conv))
        assertEquals(InstantPush.CHANNEL_QUIET, InstantPush.channelFor(InstantPush.alerts(defaults, chats, conv), InstantPush.vibrates(defaults, chats, conv)))
    }

    @Test
    fun `chats JSON that is not an object reads as nothing saved`() {
        val defaults: String? = null
        val chats = """[1,2]"""
        val conv = "conv1"
        assertTrue(InstantPush.alerts(defaults, chats, conv))
        assertTrue(InstantPush.vibrates(defaults, chats, conv))
        assertEquals(InstantPush.CHANNEL_BOTH, InstantPush.channelFor(InstantPush.alerts(defaults, chats, conv), InstantPush.vibrates(defaults, chats, conv)))
    }
}
