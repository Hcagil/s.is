package com.esd.sis

import java.net.URLEncoder
import org.json.JSONArray
import org.json.JSONObject

/**
 * Kotlin twin of notification_inbox.dart (addToInbox, inboxSummary). Works on the text the Dart side
 * keeps in shared preferences: a JSON array of chats, oldest-updated first, each
 * {"c": id, "t": title, "g": group, "l": [{"s": sender, "x": text, "a": atMillis, "m": messageId?}],
 * "n": count, "p": posted}. The native receiver stores a push here so that a chat's notification
 * keeps every unread line even while the Dart handler is still deferred.
 */
object PushInbox {
    const val MAX_LINES = 25

    /** Chats parsed from [raw]; empty on null or unreadable text. */
    fun parse(raw: String?): JSONArray {
        if (raw == null) return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            JSONArray()
        }
    }

    /**
     * [raw] with one more message for [conversationId], as JSON text. A separate [sender] and
     * [chat] (a group message) win over the title; else "Sender @ Group" is a group, else a 1:1.
     * A line whose [messageId] is already stored is not added twice.
     */
    fun add(
        raw: String?,
        conversationId: String,
        title: String,
        sender: String?,
        chat: String?,
        text: String,
        at: Long,
        messageId: String?,
    ): String {
        val chats = parse(raw)
        val existing = find(chats, conversationId)
        val old = existing?.getJSONArray("l") ?: JSONArray()
        if (messageId != null && (0 until old.length()).any { old.getJSONObject(it).optString("m") == messageId }) {
            return chats.toString()
        }

        val at3 = title.indexOf(" @ ")
        val group = !sender.isNullOrEmpty() && !chat.isNullOrEmpty() || at3 >= 0
        val lineSender = when {
            !sender.isNullOrEmpty() && !chat.isNullOrEmpty() -> sender
            at3 >= 0 -> title.substring(0, at3)
            else -> title
        }
        val chatTitle = when {
            !sender.isNullOrEmpty() && !chat.isNullOrEmpty() -> chat
            at3 >= 0 -> title.substring(at3 + 3)
            else -> title
        }

        val line = JSONObject().put("s", lineSender).put("x", text).put("a", at)
        if (messageId != null) line.put("m", messageId)
        val all = (0 until old.length()).map { old.getJSONObject(it) } + line
        val lines = JSONArray(all.takeLast(MAX_LINES))

        val updated = JSONObject()
            .put("c", conversationId)
            .put("t", chatTitle)
            .put("g", group)
            .put("l", lines)
            .put("n", (existing?.optInt("n", 0) ?: 0) + 1)
            .put("p", existing?.optInt("p", 0) ?: 0)

        val result = JSONArray()
        for (i in 0 until chats.length()) {
            if (chats.getJSONObject(i).optString("c") != conversationId) result.put(chats.getJSONObject(i))
        }
        return result.put(updated).toString()
    }

    /** The chat object for [conversationId] in [chats], or null. */
    fun find(chats: JSONArray, conversationId: String): JSONObject? {
        for (i in 0 until chats.length()) {
            val c = chats.getJSONObject(i)
            if (c.optString("c") == conversationId) return c
        }
        return null
    }

    /** '1 new message' / 'N new messages', plus ' from K chats' for several chats; '' when empty. */
    fun summary(chats: JSONArray): String {
        if (chats.length() == 0) return ""
        var total = 0
        for (i in 0 until chats.length()) total += chats.getJSONObject(i).optInt("n", 0)
        val messages = if (total == 1) "1 new message" else "$total new messages"
        return if (chats.length() > 1) "$messages from ${chats.length()} chats" else messages
    }

    /**
     * The storage path of the picture of chat [conversationId] in the chat list snapshot text
     * [snapshot] ({"v":1,"owner":id,"list":[{"id":..,"title":String?,"avatarPath":String?,"other":{"avatar":String?}?}]}):
     * a group (non-null "title") uses its own "avatarPath", a 1:1 uses "other"."avatar".
     * Null when the snapshot is missing, unreadable, belongs to another [owner], or has no picture.
     */
    fun avatarPath(snapshot: String?, owner: String, conversationId: String): String? {
        if (snapshot == null) return null
        return try {
            val root = JSONObject(snapshot)
            if (root.optString("owner") != owner) return null
            val list = root.getJSONArray("list")
            for (i in 0 until list.length()) {
                val c = list.getJSONObject(i)
                if (c.optString("id") != conversationId) continue
                val path = if (!c.isNull("title")) {
                    c.optString("avatarPath", "")
                } else {
                    c.optJSONObject("other")?.optString("avatar", "") ?: ""
                }
                return if (path.isEmpty() || path == "null") null else path
            }
            null
        } catch (e: Exception) {
            null
        }
    }

    /** The file name Dart's Uri.encodeComponent gives a storage path in the attachment cache. */
    fun cacheFileName(path: String): String =
        URLEncoder.encode(path, "UTF-8").replace("+", "%20").replace("*", "%2A")
}
