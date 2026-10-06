package com.esd.sis

import android.app.ActivityManager
import android.app.KeyguardManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
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
    private val LEGACY_CHANNELS = listOf("sis-instant", "sis-instant-sound", "sis-instant-vibrate", "sis-instant-quiet")
    const val CHANNEL_SUMMARY = "summary"
    const val SUMMARY_ID = 0

    private const val ENQUEUE_GAP_MS = 300L
    private const val QUIET_MS = 8000L

    // Per process, as Dart kept them per isolate: when this process last posted, and when its last draw ended.
    private var lastPostAt = 0L
    private var lastDrawEnd = 0L
    @Volatile private var legacyChannelsDeleted = false

    /** What one notification does once the chat's choices met the defaults (Dart's EffectiveAlert). [tone] null is the system default and is always null when [sound] is off. */
    data class Alert(val sound: Boolean, val tone: String?, val vibration: Boolean)

    /** Dart's resolveAlert: the chat's own choice over the defaults JSON ({"s","t","v"}), read from the same preferences. */
    fun effectiveAlert(defaultsJson: String?, chatsJson: String?, conversationId: String): Alert {
        val sound = alerts(defaultsJson, chatsJson, conversationId)
        val tone = if (!sound) {
            null
        } else {
            try {
                JSONObject(defaultsJson ?: "{}").let { if (it.isNull("t")) null else it.getString("t") }
            } catch (e: Exception) {
                null
            }
        }
        return Alert(sound, tone, vibrates(defaultsJson, chatsJson, conversationId))
    }

    /** Dart's FNV-1a over UTF-16 units as lower-case hex, so a custom tone maps to the channel id Dart always used. */
    private fun fnv1a(s: String): String {
        var h = 0x811c9dc5L
        for (unit in s) {
            h = ((h xor unit.code.toLong()) * 0x01000193L) and 0xffffffffL
        }
        return h.toString(16)
    }

    /** Dart's alertChannelId, e.g. msg-sys-v1, msg-off-v0, msg-1a2b3c4d-v1. */
    fun alertChannelId(a: Alert): String {
        val tone = when {
            !a.sound -> "off"
            a.tone == null -> "sys"
            else -> fnv1a(a.tone)
        }
        return "msg-$tone-v${if (a.vibration) 1 else 0}"
    }

    /** The channel's name in the phone's settings. */
    fun alertChannelName(a: Alert): String =
        "Messages" + (if (a.sound) (if (a.tone == null) "" else " (custom tone)") else " (silent)") + (if (a.vibration) "" else ", no vibration")

    /** Creates the channel for [a] if it does not exist (an existing one, with the member's own settings, is left alone) and returns its id. Same settings the notifications plugin gave it: high importance, the tone or the default notification sound, notification audio usage. */
    fun ensureAlertChannel(context: Context, a: Alert): String {
        val id = alertChannelId(a)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(id, alertChannelName(a), NotificationManager.IMPORTANCE_HIGH)
            channel.description = "New messages"
            if (a.sound) {
                val uri = if (a.tone == null) RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION) else Uri.parse(a.tone)
                channel.setSound(uri, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build())
            } else {
                channel.setSound(null, null)
            }
            channel.enableVibration(a.vibration)
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(channel)
        }
        return id
    }

    /** True when the shade has been quiet for [QUIET_MS], so this draw may make a sound; a burst alerts once. */
    @Synchronized
    fun isLoud(): Boolean = lastDrawEnd == 0L || System.currentTimeMillis() - lastDrawEnd > QUIET_MS

    @Synchronized
    private fun markDrawEnd() {
        lastDrawEnd = System.currentTimeMillis()
    }

    /** Waits only as long as it takes to leave [ENQUEUE_GAP_MS] since this process's last post (Android sheds an app's notifications past about 5 enqueues a second), then counts as a post itself. */
    @Synchronized
    private fun pace() {
        val wait = ENQUEUE_GAP_MS - (System.currentTimeMillis() - lastPostAt)
        if (lastPostAt != 0L && wait > 0) {
            try {
                Thread.sleep(wait)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        lastPostAt = System.currentTimeMillis()
    }

    /** For tests: forgets the pacing and quiet state of this process. */
    fun resetPacing() {
        lastPostAt = 0L
        lastDrawEnd = 0L
    }

    fun notificationId(conversationId: String): Int {
        var h = 0x811c9dc5L
        for (unit in conversationId) {
            h = ((h xor unit.code.toLong()) * 0x01000193L) and 0x7fffffffL
        }
        val result = h.toInt()
        return if (result == 0) 1 else result
    }

    /** Whether the native side draws this push now: high-priority pushes are drawn here too (the Dart handler no longer draws on Android). */
    fun shouldPostNow(hasNotificationBlock: Boolean, appInForeground: Boolean, owner: String?, targetUser: String?, notificationsEnabled: Boolean, hasFields: Boolean): Boolean {
        return !hasNotificationBlock && !appInForeground && owner != null && (targetUser == null || targetUser == owner) && notificationsEnabled && hasFields
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

    /** The tap contract of flutter_local_notifications, so the app opens the chat as it does for the notification Dart draws. Null when the app has no launch intent. */
    fun tapIntent(context: Context, id: Int, conversationId: String): PendingIntent? {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        launch.action = "SELECT_NOTIFICATION"
        launch.putExtra("notificationId", id)
        launch.putExtra("payload", conversationId)
        return PendingIntent.getActivity(context, id, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Whether the Reply button is drawn. API 31+ enforces unlock itself (setAuthenticationRequired); below that nothing can, so a phone with a secure lock gets no Reply at all (Mark as read stays). */
    fun replyOffered(sdk: Int, deviceSecure: Boolean): Boolean = sdk >= Build.VERSION_CODES.S || !deviceSecure

    /** The two buttons (Mark as read, Reply with a text box) for a chat's notification. The request code is the notification id; the intents differ by data, so chats and buttons never share a PendingIntent. The reply one is mutable because the system fills in the typed text. */
    fun addActions(context: Context, builder: NotificationCompat.Builder, conversationId: String, id: Int, token: String, url: String) {
        val read = PendingIntent.getBroadcast(context, id, NotificationActionReceiver.intentFor(context, conversationId, token, url, false), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        builder.addAction(NotificationCompat.Action.Builder(0, context.getString(R.string.action_mark_read), read).setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ).setShowsUserInterface(false).build())
        // Reply needs an unlocked phone: enforced by the system from API 31; below that it is simply not offered on a phone with a secure lock.
        if (!replyOffered(Build.VERSION.SDK_INT, (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceSecure)) return
        val reply = PendingIntent.getBroadcast(context, id, NotificationActionReceiver.intentFor(context, conversationId, token, url, true), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        builder.addAction(NotificationCompat.Action.Builder(0, context.getString(R.string.action_reply), reply).setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY).setShowsUserInterface(false).setAuthenticationRequired(true).addRemoteInput(androidx.core.app.RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY).setLabel(context.getString(R.string.action_reply_hint)).build()).build())
    }

    /** One silent group summary over every waiting chat (the Dart side posts the same, id 0); removed when no chat is left. Keep in sync with Dart _showSummary in local_push_display.dart. */
    fun postSummary(context: Context, inboxChats: org.json.JSONArray) {
        if (inboxChats.length() == 0) {
            NotificationManagerCompat.from(context).cancel(SUMMARY_ID)
            return
        }
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
                        val last = all.getJSONObject(all.length() - 1)
                        val who = last.optString("s")
                        s.addLine(c.optString("t") + ": " + (if (c.optBoolean("g") && who.isNotEmpty()) "$who: " else "") + last.optString("x"))
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
    }

    /** [postSummaryNow] false when more pushes are queued behind this one: the last of them posts the group summary, which depends only on the stored inbox. [paced] false skips the pacing sleeps (a big queued burst must not outlast the receiver's time limit). */
    fun show(context: Context, extras: Bundle, postSummaryNow: Boolean = true, paced: Boolean = true): Boolean {
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
                    NotificationChannel(CHANNEL_SUMMARY, "Summary", NotificationManager.IMPORTANCE_LOW),
                )
                if (!legacyChannelsDeleted) {
                    // Builds before the per-chat tone channels left these four in the phone's settings.
                    LEGACY_CHANNELS.forEach { manager.deleteNotificationChannel(it) }
                    legacyChannelsDeleted = true
                }
            }
            val defaults = prefs.getString("flutter.sis.alert_defaults", null)
            val chats = prefs.getString("flutter.sis.alert_chats", null)
            val alert = effectiveAlert(defaults, chats, conversationId)
            val channel = ensureAlertChannel(context, alert)

            val tap = tapIntent(context, id, conversationId) ?: return false
            // As before the native takeover: a high-priority push (once drawn by Dart) alerts only when the shade has been quiet; any other push always alerted.
            val loud = extras.getString("google.original_priority") != "high" || isLoud()

            val line = body(text, extras.getString("sender"), !chat.isNullOrEmpty())
            // The unread total the server computed for this member (see the push
            // payload): shown by launchers that print a number on the icon. No
            // permission involved.
            val badge = extras.getString("badge")?.toIntOrNull() ?: 0
            // This push is stored in the inbox now, so the chat's notification lists every unread line.
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
            // commit(), not apply(): written before Dart can read it, narrowing the read-modify-write race.
            prefs.edit().putString(inboxKey, inbox).commit()
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
                val name = l.optString("s").ifEmpty { if (isGroup) "" else entry.optString("t") }
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
                .setContentTitle(entry.optString("t"))
                .setContentText(line)
                .setStyle(style)
                .setLargeIcon(avatar)
                .setAutoCancel(true)
                .setContentIntent(tap)
                .setGroup(GROUP)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setWhen(System.currentTimeMillis())
                .apply { if (entry.optInt("n", 0) > 1) setSubText("${entry.optInt("n")} new messages") }
                .apply { if (!loud) setSilent(true).setOnlyAlertOnce(true) }
                .apply { if (badge > 0) setNumber(badge) }
                .apply {
                    // The buttons need the action token the push carried; an older server sends none.
                    val token = extras.getString("action_token")
                    val url = extras.getString("action_url")
                    if (!token.isNullOrEmpty() && url != null && url.startsWith("https://")) addActions(context, this, conversationId, id, token, url)
                }
                .build()

            if (paced) pace()
            NotificationManagerCompat.from(context).notify(id, notification)

            if (postSummaryNow) {
                if (paced) pace()
                postSummary(context, inboxChats)
            }
            markDrawEnd()
            return true
        } catch (e: Exception) {
            android.util.Log.w("InstantPush", "draw failed: ${e.javaClass.simpleName}")
            return false
        }
    }
}
