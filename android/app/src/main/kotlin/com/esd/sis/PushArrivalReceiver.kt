package com.esd.sis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Records when a push reached the process, and draws it at once with [InstantPush], the only
 * drawer of chat notifications on Android: the Flutter plugin hands a not-high push to a deferred
 * job that Doze or app standby can hold for 10-50 minutes, and its Dart handler no longer draws,
 * only writes the push receipt (so a Reply button is always the unlock-protected native action).
 * The Dart handler (onBackgroundPush) reads and removes the value to put native arrival time,
 * FCM delivered/original priority and whether this receiver drew the push into the push
 * receipt.
 */
class PushArrivalReceiver : BroadcastReceiver() {
    companion object {
        // Doze has held the Dart job 10-50 min; a note removed before the job runs makes Dart alert a
        // second time, so an unread note is kept a day.
        private const val STALE_AFTER_MS = 24L * 60 * 60 * 1000
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            val extras = intent.extras ?: return
            val id = extras.getString("message_id") ?: return
            if (!id.matches(Regex("^[0-9a-fA-F-]{36}$"))) return

            val delivered = extras.getString("google.delivered_priority") ?: "?"
            val original = extras.getString("google.original_priority") ?: "?"

            val drawn = InstantPush.show(context, extras)

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val editor = prefs.edit()
            editor.putString("flutter.sis.push_arrival.$id", "$now,$delivered,$original" + if (drawn) ",n" else "")

            // Housekeeping: a value the Dart handler never read goes after a day.
            for (key in prefs.all.keys) {
                if (key.startsWith("flutter.sis.push_arrival.")) {
                    val value = prefs.getString(key, null)
                    if (value != null && value.contains(",")) {
                        try {
                            val at = value.substringBefore(",").toLong()
                            if (now - at > STALE_AFTER_MS) editor.remove(key)
                        } catch (_: NumberFormatException) {
                            // Ignore invalid entries
                        }
                    }
                }
            }

            editor.apply()
        } catch (e: Exception) {
            // A measurement must never break push delivery.
        }
    }
}
