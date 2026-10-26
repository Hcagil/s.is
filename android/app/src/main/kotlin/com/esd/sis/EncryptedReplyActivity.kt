package com.esd.sis

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import java.util.UUID

/**
 * The Reply button of a private-chat notification opens this (not exported, explicit component, no UI). It never encrypts or sends:
 * it moves the typed text into [EncryptedReplyInbox] (memory only) and opens MainActivity, whose Dart code locks and sends it through the normal send queue.
 */
class EncryptedReplyActivity : Activity() {
    companion object {
        const val EXTRA_CONVERSATION = "conversation_id"
        const val EXTRA_USER = "user_id"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val conversationId = intent.getStringExtra(EXTRA_CONVERSATION)
        val userId = intent.getStringExtra(EXTRA_USER)
        val replyText = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(NotificationActionReceiver.KEY_REPLY)?.toString()?.trim()

        // The typed text must not stay in the intent (recents, a recreate).
        intent.replaceExtras(Bundle())
        setIntent(Intent())

        if (conversationId.isNullOrBlank() || userId.isNullOrBlank() || replyText.isNullOrBlank() || replyText.length > EncryptedReplyInbox.MAX_TEXT) {
            finish()
            return
        }

        // Below API 31 the system cannot hold a Reply behind the unlock: refused while the phone is locked, nothing is kept or sent, and the existing "not sent" line shows (same guard as NotificationActionReceiver).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && (getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceLocked) {
            NotificationActionReceiver().afterAction(this, conversationId, true, null, false)
            finish()
            return
        }

        // The message id is made at tap time, so a retry of this reply keeps one id.
        EncryptedReplyInbox.add(EncryptedReply(UUID.randomUUID().toString(), conversationId, userId, replyText))

        val notificationId = InstantPush.notificationId(conversationId)
        NotificationManagerCompat.from(this).cancel(notificationId)

        // Same tap contract as InstantPush.tapIntent, so the app opens the chat.
        val open = Intent(this, MainActivity::class.java)
            .setAction("SELECT_NOTIFICATION")
            .putExtra("notificationId", notificationId)
            .putExtra("payload", conversationId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(TapProof.stamp(this, open))
        finish()
    }
}
