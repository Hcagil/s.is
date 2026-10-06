package com.esd.sis

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * The "Mark as read" and "Reply" buttons of a notification the native InstantPush drew (a closed app,
 * where no Dart runs). Sends the tapped button to the notification-action function with the action
 * token the push carried, then updates the notification.
 */
class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION = "com.esd.sis.NOTIFICATION_ACTION"
        const val EXTRA_TOKEN = "token"
        const val EXTRA_URL = "url"
        const val EXTRA_CONVERSATION = "conversation_id"
        const val EXTRA_REPLY = "reply"
        const val KEY_REPLY = "sis_reply"
        const val MAX_REPLY = 4000

        fun intentFor(context: Context, conversationId: String, token: String, url: String, reply: Boolean): Intent {
            return Intent(context, NotificationActionReceiver::class.java)
                .setAction(ACTION)
                .setData(android.net.Uri.parse("sis-action://" + (if (reply) "reply" else "read") + "/" + conversationId))
                .putExtra(EXTRA_TOKEN, token)
                .putExtra(EXTRA_URL, url)
                .putExtra(EXTRA_CONVERSATION, conversationId)
                .putExtra(EXTRA_REPLY, reply)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val conversationId = intent.getStringExtra(EXTRA_CONVERSATION)
        val token = intent.getStringExtra(EXTRA_TOKEN)
        val url = intent.getStringExtra(EXTRA_URL)
        if (conversationId.isNullOrEmpty() || token.isNullOrEmpty() || url.isNullOrEmpty()) return

        val reply = intent.getBooleanExtra(EXTRA_REPLY, false)
        val text = if (reply) {
            RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_REPLY)?.toString()?.trim()
        } else null

        if (reply && (text.isNullOrEmpty() || text.length > MAX_REPLY)) return

        // Below API 31 the system cannot hold a Reply behind the unlock; a notification drawn by an older build (or before a lock was set) still has the button. Refused while the phone is locked: nothing is sent, the chat shows the "not sent" line.
        if (reply && Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceLocked
        ) {
            afterAction(context, conversationId, true, text, false)
            return
        }

        val pending = goAsync()
        Thread {
            try {
                work(context, conversationId, token, url, reply, text)
            } catch (e: Exception) {
                Log.w("NotificationAction", "failed: ${e.javaClass.simpleName}")
            } finally {
                pending.finish()
            }
        }.start()
    }

    private fun work(context: Context, conversationId: String, token: String, url: String, reply: Boolean, text: String?) {
        val body = ActionClient.requestBody(token, conversationId, reply, if (reply) java.util.UUID.randomUUID().toString() else null, text)
        var result = ActionClient.post(url, body)
        if (result == ActionResult.RETRY) {
            // Same body, so the same message id: the server never stores a reply twice.
            result = ActionClient.post(url, body)
        }
        afterAction(context, conversationId, reply, text, result == ActionResult.DONE)
    }

    private fun afterAction(context: Context, conversationId: String, reply: Boolean, text: String?, done: Boolean) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val owner = prefs.getString("flutter.sis.push_inbox_owner", null) ?: return
        val key = "flutter.sis.push_inbox.$owner"
        val raw = prefs.getString(key, null)
        val chat = PushInbox.find(PushInbox.parse(raw), conversationId)
        val manager = NotificationManagerCompat.from(context)
        val id = InstantPush.notificationId(conversationId)

        if (reply && !done) {
            // The reply box keeps spinning until the notification is replaced.
            if (chat == null) {
                manager.cancel(id)
            } else {
                showLine(context, chat, id, conversationId, context.getString(R.string.action_not_sent) + ": " + text, failed = true)
            }
            return
        }

        if (!done) return

        val inbox = PushInbox.remove(raw, conversationId)
        prefs.edit().putString(key, inbox).commit()
        manager.cancel(id)
        InstantPush.postSummary(context, PushInbox.parse(inbox))

        if (reply && chat != null) {
            showLine(context, chat, id, conversationId, text!!, failed = false)
        }
    }

    private fun showLine(context: Context, chat: JSONObject, id: Int, conversationId: String, line: String, failed: Boolean) {
        val builder = NotificationCompat.Builder(context, InstantPush.CHANNEL_SUMMARY)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setContentTitle(chat.optString("t"))
            .setContentText(line)
            .setStyle(
                NotificationCompat.MessagingStyle(Person.Builder().setName("You").build()).also {
                    if (chat.optBoolean("g")) {
                        it.setConversationTitle(chat.optString("t"))
                        it.setGroupConversation(true)
                    }
                    it.addMessage(line, System.currentTimeMillis(), null as Person?)
                },
            )
            .setGroup(InstantPush.GROUP)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(InstantPush.tapIntent(context, id, conversationId))

        if (!failed) {
            builder.setTimeoutAfter(8000)
        }

        NotificationManagerCompat.from(context).notify(id, builder.build())
    }
}
