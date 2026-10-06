package com.esd.sis

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The chat's channel from the saved settings, from the Update 1 contract, not the code. Since
 * Update 1 only the native side draws, so it must post on the very channel the Dart side created
 * per chat before (same sound, same vibration, same id): the member notices no change.
 *
 * test/fixtures/alert_channel_vectors.json was generated from the Dart reference
 * (SharedPrefsAlertStore + resolveAlert + alertChannelId); instant_push_parity_test.dart reads
 * it too, so neither language can drift alone.
 */
class InstantPushChannelTest {
    // Gradle runs unit tests with the module directory (android/app) as the working directory.
    private val vectors = JSONObject(File("../../test/fixtures/alert_channel_vectors.json").readText())
        .getJSONArray("alerts")

    private fun str(v: JSONObject, k: String): String? = if (v.isNull(k)) null else v.getString(k)

    @Test
    fun `effective alert, channel id and name follow every shared vector`() {
        assertTrue(vectors.length() >= 15)
        val mismatches = mutableListOf<String>()
        for (i in 0 until vectors.length()) {
            val v = vectors.getJSONObject(i)
            val name = v.getString("name")
            val a = InstantPush.effectiveAlert(str(v, "defaults"), str(v, "chats"), v.getString("conversation_id"))
            if (a.sound != v.getBoolean("sound")) mismatches += "$name: sound ${a.sound}"
            if (a.vibration != v.getBoolean("vibration")) mismatches += "$name: vibration ${a.vibration}"
            if (a.tone != str(v, "tone")) mismatches += "$name: tone ${a.tone}"
            val id = InstantPush.alertChannelId(a)
            if (id != v.getString("channel_id")) mismatches += "$name: id $id"
            val label = InstantPush.alertChannelName(a)
            if (label != v.getString("channel_name")) mismatches += "$name: name $label"
        }
        assertEquals(emptyList<String>(), mismatches)
    }

    // ---- the id by hand, so a vector file regenerated from a broken Dart side is caught ----

    private fun id(sound: Boolean, tone: String?, vibration: Boolean) =
        InstantPush.alertChannelId(InstantPush.Alert(sound, tone, vibration))

    @Test
    fun `silent and system-tone channels`() {
        assertEquals("msg-off-v1", id(false, null, true))
        assertEquals("msg-off-v0", id(false, null, false))
        assertEquals("msg-sys-v1", id(true, null, true))
        assertEquals("msg-sys-v0", id(true, null, false))
    }

    @Test
    fun `a custom tone is FNV-1a 32 over its UTF-16 units, lowercase hex, unpadded`() {
        // Worked out independently (Python) from the definition.
        assertEquals("msg-dcd38253-v1", id(true, "content://media/internal/audio/media/42", true))
        assertEquals("msg-dcd38253-v0", id(true, "content://media/internal/audio/media/42", false))
        assertEquals("msg-f63d20-v1", id(true, "content://media/internal/audio/media/423", true))
    }

    @Test
    fun `a tone beyond ASCII hashes its UTF-16 units, not its UTF-8 bytes`() {
        val tone = "content://media/external/audio/media/\u011f\u00fc\u015f\u2014\u266a\uD83C\uDFB5"
        assertEquals("msg-ca8959a4-v1", id(true, tone, true))
        assertNotEquals("msg-3b91ddba-v1", id(true, tone, true))
    }

    @Test
    fun `a tone only counts while sound is on`() =
        assertEquals("msg-off-v1", InstantPush.alertChannelId(
            InstantPush.effectiveAlert("""{"s":false,"t":"content://x/1","v":true}""", null, "c1"),
        ))
}
