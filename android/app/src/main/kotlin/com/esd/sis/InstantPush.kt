package com.esd.sis

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import java.io.File
import org.json.JSONObject

object InstantPush {
    const val GROUP = "sis.messages"
    const val CHANNEL_BOTH = "sis-instant"
    const val CHANNEL_SOUND = "sis-instant-sound"
    const val CHANNEL_VIBRATE = "sis-instant-vibrate"
    const val CHANNEL_QUIET = "sis-instant-quiet"
    const val CHANNEL_SUMMARY = "summary"
    const val SUMMARY_ID = 0

    fun notificationId(conversationId: String): Int {
        var h = 0x811c9dc5L
        for (unit in conversationId) {
            h = ((h xor unit.code.toLong()) * 0x01000193L) and 0x7fffffffL
        }
        val result = h.toInt()
        return if (result == 0) 1 else result
    }

    fun shouldPostNow(originalPriority: String?, hasNotificationBlock: Boolean, appInForeground: Boolean, owner: String?, targetUser: String?, notificationsEnabled: Boolean, hasFields: Boolean): Boolean {
        return originalPriority != "high" && !hasNotificationBlock && !appInForeground && owner != null && (targetUser == null || targetUser == owner) && notificationsEnabled && hasFields
    }

    private fun resolve(defaultsJson: String?, chatsJson: String?, conversationId: String, key: String): Boolean {
        val defaults = try {
            JSONObject(defaultsJson ?: "{}")
        } catch (e: Exception) {
            JSONObject("{}")
        }

        val chat = try {
            JSONObject(chatsJson ?: "{}").optJSONObject(conversationId)
        } catch (e: Exception) {
            null
        }

        return when (chat?.optString(key, "byDefault")) {
            "on" -> true
            "off" -> false
            else -> defaults.optBoolean(key, true)
        }
    }

    /** Whether the chat's SOUND resolves on (Dart's resolveAlert). Name kept for the shared-vector test. */
    fun alerts(defaultsJson: String?, chatsJson: String?, conversationId: String): Boolean =
        resolve(defaultsJson, chatsJson, conversationId, "s")

    /** Whether the chat's VIBRATION resolves on (Dart's resolveAlert). */
    fun vibrates(defaultsJson: String?, chatsJson: String?, conversationId: String): Boolean =
        resolve(defaultsJson, chatsJson, conversationId, "v")

    fun channelFor(sound: Boolean, vibration: Boolean): String = when {
        sound && vibration -> CHANNEL_BOTH
        sound -> CHANNEL_SOUND
        vibration -> CHANNEL_VIBRATE
        else -> CHANNEL_QUIET
    }

    /** The cached picture of the chat (1:1: the other person, group: its own), or null. Read from the
     * chat list snapshot (support dir) and the attachment cache (cache dir) the Dart side keeps. */
    private fun avatarFor(context: Context, owner: String, conversationId: String): Bitmap? = try {
        val snapshot = File(context.filesDir, "chat_list.json").takeIf { it.exists() }?.readText()
        val path = PushInbox.avatarPath(snapshot, owner, conversationId)
        val file = if (path == null) null else File(File(context.cacheDir, "attachments"), PushInbox.cacheFileName(path))
        if (file != null && file.exists()) BitmapFactory.decodeFile(file.path) else null
    } catch (e: Exception) {
        null
    }

    fun body(text: String, sender: String?, group: Boolean): String {
        return if (group && !sender.isNullOrEmpty()) "$sender: $text" else text
    }

    fun show(context: Context, extras: Bundle): Boolean {
        try {
            val conversationId = extras.getString("conversation_id")
            val title = extras.getString("title")
            val text = extras.getString("body")
            val hasFields = conversationId != null && title != null && text != null
            val chat = extras.getString("chat")
            val hasNotificationBlock = extras.keySet().any { it.startsWith("gcm.n.") || it.startsWith("gcm.notification.") }

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val owner = prefs.getString("flutter.sis.push_inbox_owner", null)

            val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val activities = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val appInForeground = !keyguard.isKeyguardLocked &&
                activities.runningAppProcesses?.any {
                    it.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND &&
                        it.processName == context.packageName
                } == true

            if (!shouldPostNow(
                    extras.getString("google.original_priority"),
                    hasNotificationBlock,
                    appInForeground,
                    owner,
                    extras.getString("user_id"),
                    NotificationManagerCompat.from(context).areNotificationsEnabled(),
                    hasFields,
                )
            ) {
                return false
            }
            if (conversationId == null || title == null || text == null) return false

            val id = notificationId(conversationId)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_BOTH, "Messages (instant)", NotificationManager.IMPORTANCE_HIGH).apply {
                        enableVibration(true)
                    },
                )
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_SOUND, "Messages (instant, sound only)", NotificationManager.IMPORTANCE_HIGH).apply {
                        enableVibration(false)
                    },
                )
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_VIBRATE, "Messages (instant, vibration only)", NotificationManager.IMPORTANCE_HIGH).apply {
                        enableVibration(true)
                        setSound(null, null)
                    },
                )
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_QUIET, "Messages (instant, silent)", NotificationManager.IMPORTANCE_LOW),
                )
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_SUMMARY, "Summary", NotificationManager.IMPORTANCE_LOW),
                )
            }
            val defaults = prefs.getString("flutter.sis.alert_defaults", null)
            val chats = prefs.getString("flutter.sis.alert_chats", null)
            val channel = channelFor(
                alerts(defaults, chats, conversationId),
                vibrates(defaults, chats, conversationId),
            )

            // Same tap contract as flutter_local_notifications, so the app opens the chat as it does for
            // the notification Dart draws.
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return false
            launch.action = "SELECT_NOTIFICATION"
            launch.putExtra("notificationId", id)
            launch.putExtra("payload", conversationId)
            val tap = PendingIntent.getActivity(
                context,
                id,
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val line = body(text, extras.getString("sender"), !chat.isNullOrEmpty())
            // The unread total the server computed for this member (see the push
            // payload): shown by launchers that print a number on the icon. No
            // permission involved.
            val badge = extras.getString("badge")?.toIntOrNull() ?: 0
            // The inbox is the same one the Dart handler keeps: this push is stored there now, so the
            // chat's notification lists every unread line even while the Dart handler is still deferred
            // (a closed app), and a later Dart pass drops the line it finds already stored.
            val ownerId = owner ?: return false
            val inboxKey = "flutter.sis.push_inbox.$ownerId"
            val inbox = PushInbox.add(
                prefs.getString(inboxKey, null),
                conversationId,
                title,
                extras.getString("sender"),
                chat,
                text,
                System.currentTimeMillis(),
                extras.getString("message_id"),
            )
            prefs.edit().putString(inboxKey, inbox).apply()
            val inboxChats = PushInbox.parse(inbox)
            val entry = PushInbox.find(inboxChats, conversationId) ?: return false
            val isGroup = entry.optBoolean("g")
            val avatar = avatarFor(context, ownerId, conversationId)
            val style = NotificationCompat.MessagingStyle(Person.Builder().setName("You").build())
            if (isGroup) {
                style.setConversationTitle(entry.optString("t"))
                style.setGroupConversation(true)
            }
            val lines = entry.getJSONArray("l")
            for (i in 0 until lines.length()) {
                val l = lines.getJSONObject(i)
                val name = l.optString("s")
                val person = if (name.isEmpty()) {
                    null
                } else {
                    Person.Builder().setName(name).apply {
                        if (!isGroup && avatar != null) setIcon(IconCompat.createWithBitmap(avatar))
                    }.build()
                }
                style.addMessage(l.optString("x"), l.optLong("a"), person)
            }
            val notification = NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_launcher_monochrome)
                .setColor(ContextCompat.getColor(context, R.color.notification_accent))
                .setContentTitle(title)
                .setContentText(line)
                .setStyle(style)
                .setLargeIcon(avatar)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setGroup(GROUP)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setWhen(System.currentTimeMillis())
                .apply { if (badge > 0) setNumber(badge) }
                .build()

            NotificationManagerCompat.from(context).notify(id, notification)

            // One silent group summary over every waiting chat (the Dart side posts the same, id 0).
            val summary = NotificationCompat.Builder(context, CHANNEL_SUMMARY)
                .setSmallIcon(R.drawable.ic_launcher_monochrome)
                .setColor(ContextCompat.getColor(context, R.color.notification_accent))
                .setContentTitle("SIS")
                .setContentText(PushInbox.summary(inboxChats))
                .setStyle(
                    NotificationCompat.InboxStyle().also { s ->
                        for (i in inboxChats.length() - 1 downTo 0) {
                            val c = inboxChats.getJSONObject(i)
                            val all = c.getJSONArray("l")
                            s.addLine(c.optString("t") + ": " + all.getJSONObject(all.length() - 1).optString("x"))
                        }
                        s.setSummaryText(PushInbox.summary(inboxChats))
                    },
                )
                .setGroup(GROUP)
                .setGroupSummary(true)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setAutoCancel(true)
                .build()
            NotificationManagerCompat.from(context).notify(SUMMARY_ID, summary)
            return true
        } catch (e: Exception) {
            android.util.Log.w("InstantPush", "draw failed: ${e.javaClass.simpleName}")
            return false
        }
    }
}
