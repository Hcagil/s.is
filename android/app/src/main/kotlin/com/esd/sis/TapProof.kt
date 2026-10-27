package com.esd.sis

import android.content.Context
import android.content.Intent
import java.security.MessageDigest
import java.security.SecureRandom

/** MainActivity is exported, so any app can send SELECT_NOTIFICATION; only our own immutable PendingIntents carry this per-install secret. */
object TapProof {
    private const val PREFS = "sis_tap_proof"
    private const val KEY = "secret"
    private const val EXTRA = "sisTapProof"
    private val TAP_ACTIONS = setOf("SELECT_NOTIFICATION", "SELECT_FOREGROUND_NOTIFICATION") // both are taps to flutter_local_notifications

    @Synchronized
    private fun secret(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        var secret = prefs.getString(KEY, null)
        if (secret == null) {
            val bytes = ByteArray(32)
            SecureRandom().nextBytes(bytes)
            secret = bytes.joinToString("") { "%02x".format(it) }
            prefs.edit().putString(KEY, secret).commit()
        }
        return secret
    }

    /** Marks a tap intent as ours. */
    fun stamp(context: Context, intent: Intent): Intent {
        intent.putExtra(EXTRA, secret(context))
        return intent
    }

    /** Drops a tap (action cleared) that lacks the proof, so the app just opens normally; the proof never travels on. */
    fun admit(context: Context, intent: Intent?) {
        if (intent == null || intent.action !in TAP_ACTIONS) return
        val extra = intent.getStringExtra(EXTRA)
        if (extra == null || !MessageDigest.isEqual(extra.toByteArray(Charsets.UTF_8), secret(context).toByteArray(Charsets.UTF_8))) {
            intent.action = null
        }
        intent.removeExtra(EXTRA)
    }
}
