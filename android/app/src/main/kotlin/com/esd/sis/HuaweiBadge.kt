package com.esd.sis

import android.content.Context
import android.net.Uri
import android.os.Bundle

/** Huawei launcher app-icon number (change_badge); does nothing on other phones; 0 hides it; capped at 99. */
object HuaweiBadge {
    fun set(context: Context, count: Int) {
        val n = count.coerceIn(0, 99)
        try {
            val className = context.packageManager.getLaunchIntentForPackage(context.packageName)?.component?.className ?: return
            val bundle = Bundle().apply {
                putString("package", context.packageName)
                putString("class", className)
                putInt("badgenumber", n)
            }
            context.contentResolver.call(
                Uri.parse("content://com.huawei.android.launcher.settings/badge/"),
                "change_badge",
                null,
                bundle,
            )
        } catch (e: Exception) {
            // A badge is cosmetic: not Huawei, launcher lacks it, permission missing -- ignore.
        }
    }
}
