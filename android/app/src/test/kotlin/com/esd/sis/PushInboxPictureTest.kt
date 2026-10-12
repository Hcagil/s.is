package com.esd.sis

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PushInboxPictureTest {

    @Test
    fun `right line only (other line and other chat unchanged)`() {
        var raw: String? = null
        // Add first line
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        // Add second line in same chat
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "bye", 2000L, "m2"
        )
        // Add a line in another chat
        raw = PushInbox.add(
            raw, "c2", "Bob", "Bob", null, "hey", 3000L, "m3"
        )
        // Set image on second line
        val updated = PushInbox.setImage(raw, "c1", "m2", "pic2.png")
        assertNotNull(updated)
        val arr = JSONArray(updated)
        // Chat order is not part of the contract: look chats up by id.
        val chat1 = PushInbox.find(arr, "c1")!!
        val chat2 = PushInbox.find(arr, "c2")!!
        val before = JSONArray(raw)
        // Everything except the new "i" key is unchanged.
        chat1.getJSONArray("l").getJSONObject(1).remove("i")
        assertEquals(PushInbox.find(before, "c1").toString(), chat1.toString())
        assertEquals(PushInbox.find(before, "c2").toString(), chat2.toString())
        chat1.getJSONArray("l").getJSONObject(1).put("i", "pic2.png")
        // chat1 lines
        val lines1 = chat1.getJSONArray("l")
        assertEquals(2, lines1.length())
        // first line unchanged
        val line1 = lines1.getJSONObject(0)
        assertFalse(line1.has("i"))
        // second line has i
        val line2 = lines1.getJSONObject(1)
        assertEquals("pic2.png", line2.getString("i"))
        // chat2 unchanged
        val lines2 = chat2.getJSONArray("l")
        assertEquals(1, lines2.length())
        val line3 = lines2.getJSONObject(0)
        assertFalse(line3.has("i"))
    }

    @Test
    fun `null after remove`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        raw = PushInbox.remove(raw, "c1")
        val result = PushInbox.setImage(raw, "c1", "m1", "pic.png")
        assertNull(result)
        assertNull("the read chat stays gone", PushInbox.find(PushInbox.parse(raw), "c1"))
    }

    @Test
    fun `null unknown message id`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        val result = PushInbox.setImage(raw, "c1", "unknown", "pic.png")
        assertNull(result)
    }

    @Test
    fun `null unknown chat`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        val result = PushInbox.setImage(raw, "c2", "m1", "pic.png")
        assertNull(result)
    }

    @Test
    fun `null raw`() {
        val result = PushInbox.setImage(null, "c1", "m1", "pic.png")
        assertNull(result)
    }

    @Test
    fun `null after 26 newer adds`() {
        var raw: String? = null
        // Add 26 lines in same chat
        for (i in 1..26) {
            raw = PushInbox.add(
                raw, "c1", "Ava", "Ava", null, "msg$i", 1000L + i, "m$i"
            )
        }
        // The first line (m1) should have been removed
        val result = PushInbox.setImage(raw, "c1", "m1", "pic.png")
        assertNull(result)
    }

    @Test
    fun `images from two chats`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        raw = PushInbox.add(
            raw, "c2", "Bob", "Bob", null, "hey", 2000L, "m2"
        )
        raw = PushInbox.setImage(raw, "c1", "m1", "pic1.png")!!
        raw = PushInbox.setImage(raw, "c2", "m2", "pic2.png")!!
        val imgs = PushInbox.images(raw)
        assertEquals(setOf("pic1.png", "pic2.png"), imgs)
    }

    @Test
    fun `images empty cases`() {
        assertTrue(PushInbox.images(null).isEmpty())
        assertTrue(PushInbox.images("[]").isEmpty())
        val raw = PushInbox.add(
            null, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        assertTrue(PushInbox.images(raw).isEmpty())
    }

    @Test
    fun `images after remove drops only that chat`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        raw = PushInbox.add(
            raw, "c2", "Bob", "Bob", null, "hey", 2000L, "m2"
        )
        raw = PushInbox.setImage(raw, "c1", "m1", "pic1.png")!!
        raw = PushInbox.setImage(raw, "c2", "m2", "pic2.png")!!
        raw = PushInbox.remove(raw, "c1")
        val imgs = PushInbox.images(raw)
        assertEquals(setOf("pic2.png"), imgs)
    }

    @Test
    fun `set twice keeps latest`() {
        var raw: String? = null
        raw = PushInbox.add(
            raw, "c1", "Ava", "Ava", null, "hi", 1000L, "m1"
        )
        raw = PushInbox.setImage(raw, "c1", "m1", "first.png")!!
        raw = PushInbox.setImage(raw, "c1", "m1", "second.png")!!
        val arr = JSONArray(raw)
        val chat = PushInbox.find(arr, "c1")!!
        val line = chat.getJSONArray("l").getJSONObject(0)
        assertEquals("second.png", line.getString("i"))
    }
}
