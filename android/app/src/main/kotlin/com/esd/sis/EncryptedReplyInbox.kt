package com.esd.sis

/** One Reply typed into a private-chat notification. */
data class EncryptedReply(val id: String, val conversationId: String, val userId: String, val text: String)

/** Memory only: the typed text waits here until Dart takes it (channel sis/encrypted_reply) and sends it through the encrypted send queue. Never persisted or logged; lost if the process dies first. */
object EncryptedReplyInbox {
    const val MAX_TEXT = 4000 // same cap as NotificationActionReceiver.MAX_REPLY
    private const val MAX_WAITING = 20
    private val waiting = ArrayList<EncryptedReply>()

    @Synchronized fun add(reply: EncryptedReply) {
        if (waiting.size >= MAX_WAITING) waiting.removeAt(0)
        waiting.add(reply)
    }

    @Synchronized fun take(): List<Map<String, String>> {
        val result = waiting.map { mapOf("id" to it.id, "conversation_id" to it.conversationId, "user_id" to it.userId, "text" to it.text) }
        waiting.clear()
        return result
    }
}
