package com.esd.sis
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Reaction lines in the push inbox (design A2), from the contract: drafted by test_writer, checked by qa-lead. */
class PushInboxReactionTest {
    @Test
    fun `R1 - reaction line added as line with m and x`() {
        val raw = PushInbox.add(null, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        val lines = chat.getJSONArray("l")
        assertEquals(1, lines.length())
        val line = lines.getJSONObject(0)
        assertEquals("r:M:R1", line.getString("m"))
        assertEquals("👍", line.getString("x"))
    }

    @Test
    fun `R2 - same reaction key replaces line, line count unchanged`() {
        var raw = PushInbox.add(null, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "❤️", 0L, "r:M:R1")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        val lines = chat.getJSONArray("l")
        assertEquals(1, lines.length())
        val line = lines.getJSONObject(0)
        assertEquals("r:M:R1", line.getString("m"))
        assertEquals("❤️", line.getString("x"))
    }

    @Test
    fun `R3 - different reactors give two lines`() {
        var raw = PushInbox.add(null, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "❤️", 0L, "r:M:R2")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        val lines = chat.getJSONArray("l")
        assertEquals(2, lines.length())
        val mSet = mutableSetOf<String>()
        for (i in 0 until lines.length()) {
            val line = lines.getJSONObject(i)
            mSet.add(line.getString("m"))
        }
        assertEquals(setOf("r:M:R1", "r:M:R2"), mSet)
    }

    @Test
    fun `R4 - reaction never raises n`() {
        var raw = PushInbox.add(null, "c1", "Ava", null, null, "Hello", 0L, "M")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "❤️", 0L, "r:M:R2")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "😄", 0L, "r:M:R1")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        assertEquals(1, chat.getInt("n"))
        val lines = chat.getJSONArray("l")
        assertEquals(3, lines.length())
    }

    @Test
    fun `R5 - inbox starting null + one reaction add - chat exists with one line and n = 0, summary empty`() {
        val raw = PushInbox.add(null, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        assertEquals(0, chat.getInt("n"))
        val lines = chat.getJSONArray("l")
        assertEquals(1, lines.length())
        assertEquals("", PushInbox.summary(chats))
    }

    @Test
    fun `R6 - message line and reaction line are independent, re-adding message is no-op`() {
        var raw = PushInbox.add(null, "c1", "Ava", null, null, "Hello", 0L, "M")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "👍", 0L, "r:M:R1")
        raw = PushInbox.add(raw, "c1", "Ava", null, null, "Hello", 0L, "M")
        val chats = PushInbox.parse(raw)
        val chat = PushInbox.find(chats, "c1")!!
        assertEquals(1, chat.getInt("n"))
        val lines = chat.getJSONArray("l")
        assertEquals(2, lines.length())
        var hasMessage = false
        var hasReaction = false
        for (i in 0 until lines.length()) {
            val line = lines.getJSONObject(i)
            if (line.getString("m") == "M") { hasMessage = true; assertEquals("Hello", line.getString("x")) }
            if (line.getString("m") == "r:M:R1") hasReaction = true
        }
        assertEquals(true, hasMessage)
        assertEquals(true, hasReaction)
    }
}
