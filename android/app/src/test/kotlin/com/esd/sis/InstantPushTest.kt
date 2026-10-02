package com.esd.sis

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * InstantPush's decision logic, from the 0.30.7 contract (docs/DECISIONS.md, "Android draws a
 * not-high-priority push itself, at once"), not from the code.
 *
 * The ids, group key and alert vectors are shared with the Dart side through
 * test/fixtures/instant_push_vectors.json (instant_push_parity_test.dart checks the same file
 * against LocalPushDisplay), so the two languages cannot drift apart.
 */
class InstantPushTest {
    // Gradle runs unit tests with the module directory (android/app) as the working directory.
    private val vectors = JSONObject(File("../../test/fixtures/instant_push_vectors.json").readText())

    // ---- the decision: draw now, or leave it to Dart ----

    /** A push the native side must draw: data-only, ours, backgrounded, allowed, not high. */
    private fun decide(
        originalPriority: String? = null,
        hasNotificationBlock: Boolean = false,
        appInForeground: Boolean = false,
        owner: String? = "member-a",
        targetUser: String? = "member-a",
        notificationsEnabled: Boolean = true,
        hasFields: Boolean = true,
    ) = InstantPush.shouldPostNow(
        originalPriority, hasNotificationBlock, appInForeground, owner, targetUser,
        notificationsEnabled, hasFields,
    )

    @Test
    fun `missing priority is drawn at once`() = assertTrue(decide(originalPriority = null))

    @Test
    fun `normal priority is drawn at once`() = assertTrue(decide(originalPriority = "normal"))

    @Test
    fun `high priority is left to Dart`() = assertFalse(decide(originalPriority = "high"))

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
    fun `each gate alone blocks a normal-priority push`() {
        // Every other gate passes, so a red here names the one gate that was ignored.
        assertTrue(decide(originalPriority = "normal"))
        assertFalse(decide(originalPriority = "normal", hasNotificationBlock = true))
        assertFalse(decide(originalPriority = "normal", appInForeground = true))
        assertFalse(decide(originalPriority = "normal", notificationsEnabled = false))
        assertFalse(decide(originalPriority = "normal", targetUser = "member-b"))
        assertFalse(decide(originalPriority = "normal", hasFields = false))
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

    // ---- the chat's alert choice, read from the same preferences ----

    @Test
    fun `alert choice follows the shared vectors`() {
        val alerts = vectors.getJSONArray("alerts")
        assertTrue(alerts.length() > 0)
        val wrong = mutableListOf<String>()
        for (i in 0 until alerts.length()) {
            val v = alerts.getJSONObject(i)
            val defaults = if (v.isNull("defaults")) null else v.getString("defaults")
            val chats = if (v.isNull("chats")) null else v.getString("chats")
            // Two native channels: loud and quiet. A chat whose sound resolves off must never
            // land on the loud one (it would ring); a chat whose sound resolves on must.
            val loud = InstantPush.alerts(defaults, chats, v.getString("conversation_id"))
            if (loud != v.getBoolean("sound")) wrong += "${v.getString("name")}: loud=$loud"
        }
        assertEquals(emptyList<String>(), wrong)
    }

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
