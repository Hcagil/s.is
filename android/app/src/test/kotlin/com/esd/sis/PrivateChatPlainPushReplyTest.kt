package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * A plain (not locked) push into a private chat. Written from the contract, not the code:
 * - docs/SECURITY.md "Private (encrypted) chats (I2)": the action token of every push into a chat
 *   that ever held a locked message signs `mark_read` only (per chat, not per message), and
 *   `notification_action` refuses a plain reply into such a chat (42501);
 * - test/edge/notify_encrypted_push_test.ts Group J: a plain row in such a chat travels with no
 *   `encrypted` flag and no `ct`, and its token's `a` is ['mark_read'].
 * So the phone must not draw the plain broadcast Reply (the one that calls notification-action)
 * for a token that does not allow `reply`: that reply is always refused and shows "Not sent".
 * The token is `v1.<base64url JSON {u,c,d,a,e}>.<signature>` (test/edge/action_token_test.ts).
 */
private const val OWNER = "member-a"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PrivateChatPlainPushReplyTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private var seq = 0

    @Before
    fun setUp() {
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(manager).setNotificationsEnabled(true)
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        shadowOf(am).setProcesses(
            listOf(
                ActivityManager.RunningAppProcessInfo().apply {
                    processName = app.packageName
                    pid = android.os.Process.myPid()
                    importance = ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED
                },
            ),
        )
        prefs.edit().clear().putString("flutter.sis.push_inbox_owner", OWNER).commit()
        val keyguard = shadowOf(app.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager)
        keyguard.setIsDeviceSecure(false)
        keyguard.setIsDeviceLocked(false)
        InstantPush.resetPacing()
    }

    /** A token shaped as the server signs it; the phone cannot check the signature. */
    private fun token(chat: String, vararg actions: String): String {
        val a = actions.joinToString(",") { "\"$it\"" }
        val e = System.currentTimeMillis() / 1000 + 3600
        val json = """{"u":"$OWNER","c":"$chat","d":"${"0".repeat(64)}","a":[$a],"e":$e}"""
        val payload = Base64.encodeToString(json.toByteArray(), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        return "v1.$payload.c2lnbmF0dXJl"
    }

    /** A plain push (no `encrypted`, no `ct`), as the server sends a plain row. */
    private fun draw(chat: String, vararg actions: String): Notification {
        val b = Bundle().apply {
            putString("message_id", "00000000-0000-4000-8000-%012d".format(++seq))
            putString("conversation_id", chat)
            putString("title", "Ann Sender")
            putString("body", "plain words")
            putString("sender", "Ann Sender")
            putString("chat", "Ann Sender")
            putString("user_id", OWNER)
            putString("google.original_priority", "normal")
            putString("google.delivered_priority", "normal")
            putString("action_token", token(chat, *actions))
            putString("action_url", "https://project.example/functions/v1/notification-action")
        }
        PushArrivalReceiver().onReceive(app, Intent("com.google.android.c2dm.intent.RECEIVE").apply { putExtras(b) })
        return shadowOf(manager).getNotification(InstantPush.notificationId(chat))!!
    }

    /** Buttons that go to notification-action (broadcasts), by title. */
    private fun broadcasts(n: Notification) =
        n.actions.orEmpty().filter { shadowOf(it.actionIntent).isBroadcastIntent }.map { it.title.toString() }

    @Test
    fun `a plain push whose token allows mark_read only has no plain Reply`() {
        val n = draw("c-pc-1", "mark_read")
        assertTrue("no broadcast Reply, got ${broadcasts(n)}", "Reply" !in broadcasts(n))
    }

    @Test
    fun `control - a plain push whose token allows reply keeps both plain buttons`() =
        assertEquals(listOf("Mark as read", "Reply"), broadcasts(draw("c-pc-2", "mark_read", "reply")))
}
