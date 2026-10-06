package com.esd.sis

import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/** How the server answered a notification button (twin of Dart's NotificationActionResult). */
enum class ActionResult { DONE, REJECTED, RETRY }

/** Posts one notification button to the notification-action function. Runs on the caller's thread: call it off the main thread. */
object ActionClient {
    /** Maps an HTTP status: 200 -> DONE; 429 and 5xx -> RETRY; anything else -> REJECTED. */
    fun resultFor(status: Int): ActionResult = when (status) {
        200 -> ActionResult.DONE
        429, in 500..599 -> ActionResult.RETRY
        else -> ActionResult.REJECTED
    }

    /** The JSON body notification-action expects (twin of Dart's NotificationAction.toRequest): token, conversation_id, action ("mark_read" or "reply"), and for a reply also id and body. */
    fun requestBody(token: String, conversationId: String, reply: Boolean, id: String?, text: String?): String {
        val json = JSONObject()
        json.put("token", token)
        json.put("conversation_id", conversationId)
        json.put("action", if (reply) "reply" else "mark_read")
        if (reply) {
            json.put("id", id)
            json.put("body", text)
        }
        return json.toString()
    }

    /** POSTs [body] to [url] (must start with "https://", else REJECTED) with content-type application/json, 15 s connect and read timeouts. Any IOException or other exception -> RETRY. Never throws. */
    fun post(url: String, body: String): ActionResult {
        if (!url.startsWith("https://")) return ActionResult.REJECTED
        var connection: HttpURLConnection? = null
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            connection = c
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.connectTimeout = 15000
            c.readTimeout = 15000
            c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            resultFor(c.responseCode)
        } catch (e: Exception) {
            ActionResult.RETRY
        } finally {
            connection?.disconnect()
        }
    }
}
