package com.esd.sis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Records when a push reached the process, and draws it at once with [InstantPush], the only
 * drawer of chat notifications on Android: the Flutter plugin hands a not-high push to a deferred
 * job that Doze or app standby can hold for 10-50 minutes, and its Dart handler no longer draws,
 * only writes the push receipt (so a Reply button is always the unlock-protected native action).
 * The Dart handler (onBackgroundPush) reads and removes the value to put native arrival time,
 * FCM delivered/original priority and whether this receiver drew the push into the push
 * receipt. The note is written at once as queued (",q") and settled after the draw (",n" drawn,
 * none otherwise); the draw itself runs on one background thread under goAsync, in arrival
 * order, because InstantPush paces its posts by sleeping.
 */
class PushArrivalReceiver : BroadcastReceiver() {
    companion object {
        // Doze has held the Dart job 10-50 min; a note removed before the job runs makes Dart alert a
        // second time, so an unread note is kept a day.
        private const val STALE_AFTER_MS = 24L * 60 * 60 * 1000

        // One thread keeps the draws in arrival order and the pacing gap between them (InstantPush.pace sleeps, which the main thread must never do); [queued] counts pushes accepted and not yet drawn.
        private val executor = Executors.newSingleThreadExecutor()
        private val queued = AtomicInteger(0)

        // ponytail: past 15 queued pushes the 300 ms pacing sleep is skipped, so a burst cannot hold goAsync past the ~10 s receiver limit; raise only if the limit is measured higher.
        const val PACE_CAP = 15
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
            val extras = intent.extras ?: return
            val id = extras.getString("message_id") ?: return
            if (!id.matches(Regex("^[0-9a-fA-F-]{36}$"))) return

            val delivered = extras.getString("google.delivered_priority") ?: "?"
            val original = extras.getString("google.original_priority") ?: "?"

            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val key = "flutter.sis.push_arrival.$id"
            val head = "${System.currentTimeMillis()},$delivered,$original"
            // Noted at once with ",q" (queued to be drawn) so the Dart handler, which may start before a paced draw ends, still counts the push as drawn here; the draw then settles it.
            prefs.edit().putString(key, "$head,q").apply()
            val depth = queued.incrementAndGet()
            val pending = goAsync() // null when called directly (unit tests): draw inline
            val work = Runnable {
                try {
                    val drawn = InstantPush.show(context, extras, postSummaryNow = queued.get() <= 1, paced = depth <= PACE_CAP)
                    if (prefs.contains(key)) prefs.edit().putString(key, if (drawn) "$head,n" else head).apply()
                } catch (e: Exception) {
                    // A measurement must never break push delivery.
                } finally {
                    queued.decrementAndGet()
                    pending?.finish()
                }
            }
            if (pending == null) {
                work.run()
            } else {
                try {
                    executor.execute(work)
                } catch (e: Exception) {
                    // A rejected task never runs its finally: settle the count and release the receiver here.
                    queued.decrementAndGet()
                    pending.finish()
                }
            }
            housekeeping(prefs)
        } catch (e: Exception) {
            // A measurement must never break push delivery.
        }
    }

    private fun housekeeping(prefs: SharedPreferences) {
        try {
            val now = System.currentTimeMillis()
            val editor = prefs.edit()

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
