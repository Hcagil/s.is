package com.esd.sis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Measurement only: records when a push reached the process.
 * The Dart handler (onBackgroundPush) reads and removes the value to put native arrival time
 * and FCM delivered/original priority into the push receipt, so production shows whether a
 * late push was late at the phone or inside the Flutter plugin hand-off.
 */
class PushArrivalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val extras = intent.extras ?: return
            val id = extras.getString("message_id") ?: return
            if (!id.matches(Regex("^[0-9a-fA-F-]{36}$"))) return

            val delivered = extras.getString("google.delivered_priority") ?: "?"
            val original = extras.getString("google.original_priority") ?: "?"

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val editor = prefs.edit()
            editor.putString("flutter.sis.push_arrival.$id", "$now,$delivered,$original")

            // Housekeeping: a value the Dart handler never read goes after an hour.
            for (key in prefs.all.keys) {
                if (key.startsWith("flutter.sis.push_arrival.")) {
                    val value = prefs.getString(key, null)
                    if (value != null && value.contains(",")) {
                        try {
                            val at = value.substringBefore(",").toLong()
                            if (now - at > 3_600_000) editor.remove(key)
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
