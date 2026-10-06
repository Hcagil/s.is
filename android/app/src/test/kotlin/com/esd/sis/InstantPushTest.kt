package com.esd.sis

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * InstantPush's decision logic, from the Update 1 contract (the native side is the only drawer on
 * Android, for a push of any priority), not from the code.
 *
 * The ids, group key and alert vectors are shared with the Dart side through
 * test/fixtures/instant_push_vectors.json (instant_push_parity_test.dart checks the same file
 * against LocalPushDisplay), so the two languages cannot drift apart.
 */
class InstantPushTest {
    // Gradle runs unit tests with the module directory (android/app) as the working directory.
    private val vectors = JSONObject(File("../../test/fixtures/instant_push_vectors.json").readText())

    // ---- the decision: draw now, or leave it to Dart ----

    /** A push the native side must draw: data-only, ours, backgrounded, allowed. */
    private fun decide(
        hasNotificationBlock: Boolean = false,
        appInForeground: Boolean = false,
        owner: String? = "member-a",
        targetUser: String? = "member-a",
        notificationsEnabled: Boolean = true,
        hasFields: Boolean = true,
    ) = InstantPush.shouldPostNow(
        hasNotificationBlock, appInForeground, owner, targetUser,
        notificationsEnabled, hasFields,
    )

    /** Priority is not an input any more: any priority is drawn (PushArrivalReceiverTest). */
    @Test
    fun `a push passing every gate is drawn at once`() = assertTrue(decide())

    @Test
    fun `a push with a notification block is not ours`() =
        assertFalse(decide(hasNotificationBlock = true))

    @Test
    fun `app in the foreground draws nothing`() = assertFalse(decide(appInForeground = true))

    @Test
    fun `notifications disabled draws nothing`() = assertFalse(decide(notificationsEnabled = false))

    @Test
    fun `owner mismatch draws nothing`() = assertFalse(decide(targetUser = "member-b"))

    @Test
    fun `no signed-in owner draws nothing`() {
        assertFalse(decide(owner = null))
        // Nobody signed in and a push naming nobody: still nobody's.
        assertFalse(decide(owner = null, targetUser = null))
    }

    /** As the Dart handler: a server from before user_id was sent still draws for the signed-in member. */
    @Test
    fun `a push naming no user draws for the signed-in member`() = assertTrue(decide(targetUser = null))

    @Test
    fun `missing title, body or conversation draws nothing`() = assertFalse(decide(hasFields = false))

    @Test
    fun `each gate alone blocks a push`() {
        // Every other gate passes, so a red here names the one gate that was ignored.
        assertTrue(decide())
        assertFalse(decide(hasNotificationBlock = true))
        assertFalse(decide(appInForeground = true))
        assertFalse(decide(notificationsEnabled = false))
        assertFalse(decide(targetUser = "member-b"))
        assertFalse(decide(hasFields = false))
    }

    // ---- Reply: offered on API 31+ (behind an unlock), or with no secure lock ----

    @Test
    fun `reply is offered on API 31 and later whatever the lock`() {
        for (sdk in listOf(31, 33, 34, 35)) {
            assertTrue("$sdk secure", InstantPush.replyOffered(sdk, true))
            assertTrue("$sdk open", InstantPush.replyOffered(sdk, false))
        }
    }

    @Test
    fun `reply is withheld on API 30 and older only behind a secure lock`() {
        for (sdk in listOf(26, 29, 30)) {
            assertFalse("$sdk secure", InstantPush.replyOffered(sdk, true))
            assertTrue("$sdk open", InstantPush.replyOffered(sdk, false))
        }
    }

    // ---- the id: the Dart side's, so Dart replaces it in place ----

    @Test
    fun `notification ids match the shared vectors`() {
        val ids = vectors.getJSONArray("ids")
        assertTrue(ids.length() > 0)
        for (i in 0 until ids.length()) {
            val v = ids.getJSONObject(i)
            val conversation = v.getString("conversation_id")
            assertEquals(conversation, v.getInt("id"), InstantPush.notificationId(conversation))
        }
    }

    @Test
    fun `ids are positive and never the summary id 0`() {
        val ids = vectors.getJSONArray("ids")
        for (i in 0 until ids.length()) {
            val id = InstantPush.notificationId(ids.getJSONObject(i).getString("conversation_id"))
            assertTrue("$id", id > 0)
        }
    }

    @Test
    fun `group key matches the Dart side`() = assertEquals(vectors.getString("group_key"), InstantPush.GROUP)

    // The chat's sound, vibration and channel: InstantPushChannelTest.

    // ---- the line: "Sender: message" in a group ----

    @Test
    fun `a group line is prefixed by its sender`() =
        assertEquals("Ann Sender: hello", InstantPush.body("hello", "Ann Sender", true))

    @Test
    fun `a direct line is the text alone`() =
        assertEquals("hello", InstantPush.body("hello", "Ann Sender", false))

    @Test
    fun `a group line without a sender is the text alone`() {
        assertEquals("hello", InstantPush.body("hello", null, true))
        assertEquals("hello", InstantPush.body("hello", "", true))
    }
}
