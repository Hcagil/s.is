package com.esd.sis

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

object InstantPush {
    const val GROUP = "sis.messages"
    const val CHANNEL_BOTH = "sis-instant"
    const val CHANNEL_SOUND = "sis-instant-sound"
    const val CHANNEL_VIBRATE = "sis-instant-vibrate"
    const val CHANNEL_QUIET = "sis-instant-quiet"

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
            val notification = NotificationCompat.Builder(context, channel)
                .setSmallIcon(R.drawable.ic_launcher_monochrome)
                .setColor(ContextCompat.getColor(context, R.color.notification_accent))
                .setContentTitle(title)
                .setContentText(line)
                .setStyle(NotificationCompat.BigTextStyle().bigText(line))
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setGroup(GROUP)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setWhen(System.currentTimeMillis())
                .build()

            NotificationManagerCompat.from(context).notify(id, notification)
            return true
        } catch (e: Exception) {
            android.util.Log.w("InstantPush", "draw failed: ${e.javaClass.simpleName}")
            return false
        }
    }
}
