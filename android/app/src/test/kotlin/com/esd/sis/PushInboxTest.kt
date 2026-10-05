package com.esd.sis

import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * PushInbox, from the Update 1 slice 11a contract, not the code. The receiver writes the inbox the
 * deferred Dart handler later extends, so the JSON is held to test/fixtures/push_inbox_vectors.json,
 * which push_inbox_parity_test.dart checks against the Dart side.
 */
class PushInboxTest {
    // Gradle runs unit tests with the module directory (android/app) as the working directory.
    private val vectors = JSONObject(File("../../test/fixtures/push_inbox_vectors.json").readText())

    /** JSON as plain Kotlin values, numbers as Long, so key order and number width do not matter. */
    private fun plain(v: Any?): Any? = when (v) {
        is JSONObject -> v.keys().asSequence().associateWith { plain(v.get(it)) }
        is JSONArray -> (0 until v.length()).map { plain(v.get(it)) }
        is Number -> v.toLong()
        JSONObject.NULL -> null
        else -> v
    }

    private fun JSONObject.str(key: String): String? = if (isNull(key)) null else getString(key)

    private fun objects(key: String, from: JSONObject = vectors) =
        from.getJSONArray(key).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }

    @Test
    fun `add follows the shared vectors`() {
        for (v in objects("adds")) {
            var raw: String? = v.str("start")
            for (s in objects("steps", v)) {
                raw = PushInbox.add(
                    raw, s.getString("conversation_id"), s.getString("title"), s.str("sender"),
                    s.str("chat"), s.getString("text"), s.getLong("at"), s.str("message_id"),
                )
            }
            assertEquals(v.getString("name"), plain(v.getJSONArray("inbox")), plain(JSONArray(raw)))
        }
    }

    @Test
    fun `the line limit is the shared one`() = assertEquals(vectors.getInt("max_lines"), PushInbox.MAX_LINES)

    @Test
    fun `summary follows the shared vectors`() {
        for (v in objects("summaries")) {
            assertEquals(v.getString("text"), PushInbox.summary(v.getJSONArray("inbox")))
        }
    }

    @Test
    fun `parse of nothing is an empty inbox`() = assertEquals(0, PushInbox.parse(null).length())

    @Test
    fun `parse then find returns the chat by id, or null`() {
        val chats = PushInbox.parse(
            """[{"c":"c1","t":"Ava","g":false,"l":[],"n":1,"p":0},{"c":"g1","t":"Team","g":true,"l":[],"n":2,"p":1}]""",
        )
        assertEquals(2, chats.length())
        assertEquals("Team", PushInbox.find(chats, "g1")!!.getString("t"))
        assertEquals("Ava", PushInbox.find(chats, "c1")!!.getString("t"))
        assertNull(PushInbox.find(chats, "nope"))
    }

    @Test
    fun `avatarPath follows the shared vectors`() {
        val avatars = vectors.getJSONObject("avatars")
        val snapshot = avatars.getString("snapshot")
        for (v in objects("cases", avatars)) {
            assertEquals(
                v.getString("name"),
                v.str("path"),
                PushInbox.avatarPath(snapshot, v.getString("owner"), v.getString("conversation_id")),
            )
        }
    }

    @Test
    fun `avatarPath of a snapshot that is not JSON, or no snapshot, is null`() {
        assertNull(PushInbox.avatarPath("{not json", "member-a", "c1"))
        assertNull(PushInbox.avatarPath(null, "member-a", "c1"))
    }

    @Test
    fun `cacheFileName is Dart's Uri encodeComponent`() {
        val names = objects("cache_names")
        val want = names.map { it.getString("path") to it.getString("file") }
        val got = names.map { it.getString("path") to PushInbox.cacheFileName(it.getString("path")) }
        assertEquals(want, got)
    }
}
