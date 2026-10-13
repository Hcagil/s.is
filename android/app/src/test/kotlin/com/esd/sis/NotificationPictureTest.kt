package com.esd.sis

import android.Manifest
import android.app.ActivityManager
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import org.json.JSONArray
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import android.content.ComponentName
import android.content.Intent

/**
 * Update 2 step 12 on Android, from the contract, against a real local HTTPS server (no fake
 * connection): NotificationPicture.fetch(context, url, video, messageId) -> file name or null:
 * https only, 4 s timeouts, no redirects, at most 256 KiB, name `<uuid>.jpg` under cacheDir/notif,
 * pictures older than 1 h pruned; a video gets a play mark. InstantPush.wantsPicture /
 * attachPicture, and show(redraw = true): silent, no inbox line added; a chat read meanwhile is
 * never brought back.
 */
private const val OWNER = "member-a"
private const val INBOX = "flutter.sis.push_inbox.$OWNER"

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotificationPictureTest {
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val prefs = app.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val dir get() = File(app.cacheDir, "notif")
    private var seq = 0

    /** A minimal HTTP/1.1 server (the android.jar classpath has no com.sun httpserver). */
    private class Tiny(ssl: SSLContext?, val handle: (String) -> ByteArray) {
        val socket: ServerSocket = (ssl?.serverSocketFactory?.createServerSocket(0, 50, LOOPBACK)
            ?: ServerSocket(0, 50, LOOPBACK))
        val port get() = socket.localPort
        private val pool = Executors.newCachedThreadPool()

        init {
            Thread {
                while (!socket.isClosed) {
                    val s = try { socket.accept() } catch (e: Exception) { break }
                    pool.execute { serve(s) }
                }
            }.apply { isDaemon = true }.start()
        }

        private fun serve(s: Socket): Unit = try { s.use { answer(s) } } catch (e: Exception) { serverErrors.add(e.toString()); Unit }

        private fun answer(s: Socket) {
            val head = StringBuilder()
            val input = s.getInputStream()
            while (!head.endsWith("\r\n\r\n")) {
                val b = input.read()
                if (b < 0) return
                head.append(b.toChar())
            }
            val path = head.lineSequence().first().split(" ")[1]
            s.getOutputStream().apply { write(handle(path)); flush() }
        }

        fun stop() {
            socket.close()
            pool.shutdownNow()
        }
    }

    companion object {
        // Any address: "localhost" may resolve to ::1 (the host-case test needs a name, not an IP).
        private val LOOPBACK: InetAddress? = null
        private lateinit var https: Tiny
        private lateinit var plain: Tiny
        private val hits = ConcurrentHashMap<String, AtomicInteger>()

        /** What went wrong on the server side (a failed handshake shows here, not in the client). */
        val serverErrors = java.util.concurrent.ConcurrentLinkedQueue<String>()

        /** Served bodies by path; filled per test. Unknown paths answer 404. */
        private val bodies = ConcurrentHashMap<String, ByteArray>()

        private fun reply(status: String, extra: String = "", body: ByteArray = ByteArray(0)) =
            "HTTP/1.1 $status\r\n${extra}Content-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray() + body

        private fun handle(p: String): ByteArray {
            hits.getOrPut(p) { AtomicInteger() }.incrementAndGet()
            return when {
                p == "/redirect" -> reply("302 Found", "Location: /pic\r\n")
                p == "/stall" -> {
                    Thread.sleep(15_000)
                    reply("204 No Content")
                }
                bodies[p] != null -> reply("200 OK", "Content-Type: image/jpeg\r\n", bodies[p]!!)
                else -> reply("404 Not Found")
            }
        }

        @JvmStatic
        @BeforeClass
        fun startServers() {
            // A throwaway certificate for 127.0.0.1, made by the JDK's own keytool.
            val ks = File.createTempFile("notif", ".p12").apply { delete() }
            val keytool = File(System.getProperty("java.home"), "bin/keytool").path
            val made = ProcessBuilder(
                keytool, "-genkeypair", "-alias", "t", "-keyalg", "RSA", "-keysize", "2048",
                "-dname", "CN=127.0.0.1", "-ext", "SAN=ip:127.0.0.1,dns:localhost", "-validity", "2",
                "-storetype", "PKCS12", "-keystore", ks.path, "-storepass", "changeit", "-keypass", "changeit",
            ).redirectErrorStream(true).start()
            check(made.waitFor() == 0) { made.inputStream.bufferedReader().readText() }
            val store = KeyStore.getInstance("PKCS12").apply { FileInputStream(ks).use { load(it, "changeit".toCharArray()) } }
            val kmf = KeyManagerFactory.getInstance("SunX509", "SunJSSE").apply { init(store, "changeit".toCharArray()) }
            val serverCtx = SSLContext.getInstance("TLS", "SunJSSE").apply { init(kmf.keyManagers, null, null) }
            https = Tiny(serverCtx, ::handle)
            plain = Tiny(null, ::handle)
            // The device trusts real CAs; here the client trusts the test certificate.
            val trustAll = object : X509TrustManager {
                override fun checkClientTrusted(c: Array<X509Certificate>, a: String) {}
                override fun checkServerTrusted(c: Array<X509Certificate>, a: String) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            }
            HttpsURLConnection.setDefaultSSLSocketFactory(
                SSLContext.getInstance("TLS", "SunJSSE").apply { init(null, arrayOf(trustAll), null) }.socketFactory,
            )
            HttpsURLConnection.setDefaultHostnameVerifier { _, _ -> true }
        }

        @JvmStatic
        @AfterClass
        fun stopServers() {
            https.stop()
            plain.stop()
        }
    }

    private fun httpsUrl(path: String) = "https://127.0.0.1:${https.port}$path"
    private fun httpUrl(path: String) = "http://127.0.0.1:${plain.port}$path"
    private fun hits(path: String) = hits[path]?.get() ?: 0
    private fun nextId() = "00000000-0000-4000-8000-%012d".format(++seq)

    /** A real JPEG: plain black, so a play mark shows as changed pixels. */
    private fun jpeg(w: Int = 160, h: Int = 120): ByteArray {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }
        return ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
    }

    @Before
    fun setUp() {
        // FileProvider caches its roots statically, but Robolectric gives every test a new
        // cacheDir: forget the previous test's root (a device keeps one cacheDir for life).
        androidx.core.content.FileProvider::class.java.getDeclaredField("sCache").apply { isAccessible = true }
            .let { (it.get(null) as MutableMap<*, *>).clear() }
        hits.clear()
        bodies.clear()
        bodies["/pic"] = jpeg()
        dir.deleteRecursively()
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
        InstantPush.resetPacing()
    }

    // ---- NotificationPicture.fetch ----

    @Test
    fun `an https picture is stored under cacheDir notif, named for the message`() {
        val id = nextId()
        val name = NotificationPicture.fetch(app, httpsUrl("/pic"), false, id)
        assertEquals("server errors: $serverErrors", "$id.jpg", name)
        val f = File(dir, name!!)
        assertTrue("stored in cacheDir/notif", f.isFile && f.length() > 0)
        assertEquals(f.canonicalPath, NotificationPicture.file(app, name)!!.canonicalPath)
        val bmp = BitmapFactory.decodeFile(f.path)
        assertNotNull("a picture", bmp)
        assertEquals(160, bmp.width)
        assertEquals(1, hits("/pic"))
    }

    @Test
    fun `a plain http link is refused without a request`() {
        assertNull(NotificationPicture.fetch(app, httpUrl("/pic"), false, nextId()))
        assertEquals("no request over http", 0, hits("/pic"))
        assertFalse(dir.listFiles().orEmpty().isNotEmpty())
    }

    @Test
    fun `a message id that is not a uuid never names a file`() {
        for (bad in listOf("../../shared_prefs/x", "not-a-uuid", "", "00000000-0000-4000-8000-00000000000g")) {
            assertNull(bad, NotificationPicture.fetch(app, httpsUrl("/pic"), false, bad))
        }
        assertTrue("nothing stored", dir.listFiles().orEmpty().isEmpty())
        assertFalse(File(app.dataDir, "shared_prefs/x.jpg").exists())
        assertNull(NotificationPicture.file(app, "../x.jpg"))
    }

    @Test
    fun `a redirect is not followed`() {
        assertNull(NotificationPicture.fetch(app, httpsUrl("/redirect"), false, nextId()))
        assertEquals(1, hits("/redirect"))
        assertEquals("the redirect target is never asked", 0, hits("/pic"))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `a missing picture gives null`() {
        assertNull(NotificationPicture.fetch(app, httpsUrl("/gone"), false, nextId()))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `a body over 256 KiB is refused, one under it is taken`() {
        val pic = jpeg()
        bodies["/big"] = pic + ByteArray(262_145 - pic.size)
        bodies["/fits"] = pic + ByteArray(200 * 1024 - pic.size)
        assertNull("over the cap", NotificationPicture.fetch(app, httpsUrl("/big"), false, nextId()))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
        val id = nextId()
        assertEquals("under the cap", "$id.jpg", NotificationPicture.fetch(app, httpsUrl("/fits"), false, id))
    }

    @Test(timeout = 30_000)
    fun `a stalled server is given up after about 4 s`() {
        val started = System.currentTimeMillis()
        assertNull(NotificationPicture.fetch(app, httpsUrl("/stall"), false, nextId()))
        val took = System.currentTimeMillis() - started
        assertTrue("gave up after $took ms", took in 3_000..7_000)
    }

    @Test
    fun `a video poster gets a play mark, a photo does not`() {
        val photo = BitmapFactory.decodeFile(File(dir, NotificationPicture.fetch(app, httpsUrl("/pic"), false, nextId())!!).path)
        val video = BitmapFactory.decodeFile(File(dir, NotificationPicture.fetch(app, httpsUrl("/pic"), true, nextId())!!).path)
        fun changed(b: Bitmap): Int {
            var n = 0
            for (x in 0 until b.width) for (y in 0 until b.height) {
                val c = b.getPixel(x, y)
                if (Color.red(c) + Color.green(c) + Color.blue(c) > 120) n++
            }
            return n
        }
        assertEquals("the photo stays black", 0, changed(photo))
        assertTrue("the poster carries a mark", changed(video) > 100)
        assertEquals(photo.width, video.width)
    }

    @Test
    fun `pictures older than an hour are pruned, fresh ones stay`() {
        dir.mkdirs()
        val old = File(dir, "${nextId()}.jpg").apply { writeBytes(jpeg()); setLastModified(System.currentTimeMillis() - 2 * 3_600_000L) }
        val fresh = File(dir, "${nextId()}.jpg").apply { writeBytes(jpeg()); setLastModified(System.currentTimeMillis() - 30 * 60_000L) }
        NotificationPicture.prune(app, emptySet())
        assertFalse("over 1 h old", old.exists())
        assertTrue("30 min old", fresh.exists())
    }

    // ---- InstantPush ----

    /** A push as the edge function sends it: the picture link is on the action_url's host. */
    private fun extras(
        chat: String,
        id: String,
        thumb: String? = httpsUrl("/pic"),
        kind: String = "photo",
        action: String = httpsUrl("/functions/v1/notification-action"),
    ) = Bundle().apply {
        putString("action_token", "v1.ticket.sig")
        putString("action_url", action)
        putString("message_id", id)
        putString("conversation_id", chat)
        putString("title", "Edge Team")
        putString("body", "a photo")
        putString("sender", "Ann Sender")
        putString("chat", "Edge Team")
        putString("user_id", OWNER)
        putString("google.original_priority", "normal")
        putString("google.delivered_priority", "normal")
        if (thumb != null) {
            putString("thumb_url", thumb)
            putString("thumb_kind", kind)
        }
    }

    private fun posted(chat: String): Notification? = shadowOf(manager).getNotification(InstantPush.notificationId(chat))

    private fun silent(n: Notification) =
        n.groupAlertBehavior == Notification.GROUP_ALERT_SUMMARY || n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0

    private fun inboxLines(chat: String): JSONArray? = PushInbox.find(PushInbox.parse(prefs.getString(INBOX, null)), chat)?.getJSONArray("l")

    /** Whether the drawn notification carries a picture: a big picture, or a message with an image. */
    private fun showsPicture(n: Notification): Boolean {
        val e = n.extras
        if (e.get(Notification.EXTRA_PICTURE) != null || e.get("android.pictureIcon") != null) return true
        val msgs = e.getParcelableArray(Notification.EXTRA_MESSAGES).orEmpty()
        return msgs.any { (it as? Bundle)?.get("uri") != null }
    }

    private fun dump(n: Notification) = n.extras.keySet().joinToString { it } + " msgs=" +
        n.extras.getParcelableArray(Notification.EXTRA_MESSAGES).orEmpty().joinToString { b -> (b as Bundle).keySet().joinToString { k -> "$k=${b.get(k)}" } }

    @Test
    fun `wantsPicture follows the thumb link`() {
        assertTrue(InstantPush.wantsPicture(extras("c", nextId())))
        assertFalse(InstantPush.wantsPicture(extras("c", nextId(), thumb = null)))
    }

    @Test
    fun `the text is drawn without the picture, which is then attached to its line`() {
        val id = nextId()
        val e = extras("pc", id)
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.resetPacing() // the shade is quiet: only the redraw rule keeps the picture silent
        assertEquals("the text drew before any download", 0, hits("/pic"))
        assertFalse(showsPicture(posted("pc")!!))
        InstantPush.attachPicture(app, e)
        assertEquals(1, hits("/pic"))
        val lines = inboxLines("pc")!!
        assertEquals("still one line", 1, lines.length())
        assertEquals("$id.jpg", lines.getJSONObject(0).optString("i"))
        assertTrue(File(dir, "$id.jpg").isFile)
        assertTrue("redrawn with the picture: ${dump(posted("pc")!!)}", showsPicture(posted("pc")!!))
        assertTrue("the picture arrives without a second sound", silent(posted("pc")!!))
    }

    @Test
    fun `attaching a picture prunes pictures over an hour old`() {
        dir.mkdirs()
        val stale = File(dir, "${nextId()}.jpg").apply { writeBytes(jpeg()); setLastModified(System.currentTimeMillis() - 2 * 3_600_000L) }
        val e = extras("pr", nextId())
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.attachPicture(app, e)
        assertFalse(stale.exists())
    }

    @Test
    fun `a redraw of a chat no longer in the inbox draws nothing`() {
        val e = extras("gone", nextId())
        assertTrue(InstantPush.show(app, e, paced = false))
        prefs.edit().putString(INBOX, PushInbox.remove(prefs.getString(INBOX, null), "gone")).commit()
        manager.cancel(InstantPush.notificationId("gone"))
        InstantPush.show(app, e, paced = false, redraw = true)
        assertNull(posted("gone"))
        assertNull(inboxLines("gone"))
    }

    // ---- the receiver: the text never waits for a picture ----

    private fun waitFor(what: String, ms: Long, check: () -> Boolean) {
        val until = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < until) {
            ShadowLooper.idleMainLooper()
            if (check()) return
            Thread.sleep(5)
        }
        throw AssertionError("not within $ms ms: $what")
    }

    private fun broadcast(e: Bundle) =
        app.sendBroadcast(
            Intent("com.google.android.c2dm.intent.RECEIVE").apply {
                putExtras(e)
                component = ComponentName(app, PushArrivalReceiver::class.java)
            },
        )

    @Test(timeout = 30_000)
    fun `a stalled picture delays neither its own text nor the next message`() {
        broadcast(extras("s1", nextId(), thumb = httpsUrl("/stall")))
        waitFor("the first text", 3_000) { posted("s1") != null }
        waitFor("the stalled download started", 3_000) { hits("/stall") == 1 }
        broadcast(extras("s2", nextId(), thumb = null))
        waitFor("the next text while the picture still stalls", 3_000) { posted("s2") != null }
        assertFalse(showsPicture(posted("s1")!!))
    }

    @Test(timeout = 30_000)
    fun `a pushed photo ends with its picture in the shade`() {
        val id = nextId()
        broadcast(extras("s3", id))
        waitFor("the text, then the picture", 10_000) { posted("s3")?.let(::showsPicture) == true }
        assertEquals("$id.jpg", inboxLines("s3")!!.getJSONObject(0).optString("i"))
    }

    @Test
    fun `a redraw is silent and adds no inbox line`() {
        val e = extras("rd", nextId())
        assertTrue(InstantPush.show(app, e, paced = false))
        assertFalse("fixture: the first draw alerts", silent(posted("rd")!!))
        val before = prefs.getString(INBOX, null)
        InstantPush.resetPacing() // the shade is quiet, so a normal draw would alert again
        assertTrue(InstantPush.show(app, e, paced = false, redraw = true))
        assertTrue("the redraw makes no sound", silent(posted("rd")!!))
        assertEquals("the inbox is untouched", before, prefs.getString(INBOX, null))
    }

    @Test
    fun `a chat read before its picture arrives is not brought back`() {
        val e = extras("rr", nextId())
        assertTrue(InstantPush.show(app, e, paced = false))
        // The member opens the chat: its lines leave the inbox and its notification is cleared.
        prefs.edit().putString(INBOX, PushInbox.remove(prefs.getString(INBOX, null), "rr")).commit()
        manager.cancel(InstantPush.notificationId("rr"))
        InstantPush.attachPicture(app, e)
        assertNull("no notification comes back", posted("rr"))
        assertNull("the chat stays out of the inbox", inboxLines("rr"))
    }

    @Test
    fun `a picture that cannot be fetched leaves the text notification as it was`() {
        val e = extras("nf", nextId(), thumb = httpsUrl("/gone"))
        assertTrue(InstantPush.show(app, e, paced = false))
        val before = prefs.getString(INBOX, null)
        InstantPush.attachPicture(app, e)
        assertNotNull("the text stays", posted("nf"))
        assertFalse(showsPicture(posted("nf")!!))
        assertEquals(before, prefs.getString(INBOX, null))
    }

    // ---- fix round 1: host rule, sign-in, size ----

    @Test
    fun `a picture link on another host than the push's action_url is never fetched`() {
        // Its own path: a background fetch left over from another test cannot count here.
        bodies["/oh"] = jpeg()
        val e = extras("oh", nextId(), thumb = httpsUrl("/oh"), action = "https://project.example/functions/v1/notification-action")
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.attachPicture(app, e)
        assertEquals("no request to a foreign host", 0, hits("/oh"))
        assertFalse(showsPicture(posted("oh")!!))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `the host rule ignores case`() {
        bodies["/hc"] = jpeg()
        val e = extras("hc", nextId(), thumb = httpsUrl("/hc"), action = "https://LOCALHOST.invalid/x")
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.attachPicture(app, e)
        assertEquals("a different host is still different", 0, hits("/hc"))
        // Same host, other case: 127.0.0.1 has no case, so use the server by name.
        val id = nextId()
        val upper = extras("hu", id, thumb = "https://LocalHost:${https.port}/pic", action = "https://localhost:${https.port}/a")
        assertTrue(InstantPush.show(app, upper, paced = false))
        InstantPush.attachPicture(app, upper)
        assertEquals("hits=${hits("/pic")}", "$id.jpg", inboxLines("hu")!!.getJSONObject(0).optString("i"))
    }

    @Test
    fun `a push without action_url fetches nothing`() {
        bodies["/na"] = jpeg()
        val e = extras("na", nextId(), thumb = httpsUrl("/na")).apply { remove("action_url") }
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.attachPicture(app, e)
        assertEquals(0, hits("/na"))
    }

    @Test
    fun `nobody signed in - no fetch`() {
        bodies["/ns"] = jpeg()
        val e = extras("ns", nextId(), thumb = httpsUrl("/ns"))
        assertTrue(InstantPush.show(app, e, paced = false))
        prefs.edit().remove("flutter.sis.push_inbox_owner").commit()
        InstantPush.attachPicture(app, e)
        assertEquals("no download for a signed-out phone", 0, hits("/ns"))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun `a picture over 2048 px is stored at most 2048 px`() {
        bodies["/wide"] = jpeg(3000, 1000)
        val id = nextId()
        assertEquals("$id.jpg", NotificationPicture.fetch(app, httpsUrl("/wide"), false, id))
        val b = BitmapFactory.decodeFile(File(dir, "$id.jpg").path)
        assertTrue("${b.width}x${b.height}", b.width in 1..2048 && b.height in 1..2048)
        assertTrue("downsampled, not cropped to a sliver: ${b.width}x${b.height}", b.width >= 1000)
    }

    /** A tiny JPEG whose header claims [w] x [h] pixels (a decompression bomb). */
    private fun claiming(w: Int, h: Int): ByteArray {
        val b = jpeg(16, 16)
        // SOF0 (FF C0): length(2) precision(1) height(2) width(2)
        val i = (0 until b.size - 1).first { b[it] == 0xFF.toByte() && b[it + 1] == 0xC0.toByte() }
        b[i + 5] = (h shr 8).toByte(); b[i + 6] = h.toByte()
        b[i + 7] = (w shr 8).toByte(); b[i + 8] = w.toByte()
        return b
    }

    @Test
    fun `a small file claiming huge dimensions does not crash, and the text stays`() {
        bodies["/bomb"] = claiming(60_000, 60_000)
        val id = nextId()
        val name = NotificationPicture.fetch(app, httpsUrl("/bomb"), false, id)
        if (name != null) {
            val b = BitmapFactory.decodeFile(File(dir, name).path)
            assertTrue("stored small: ${b.width}x${b.height}", b.width <= 2048 && b.height <= 2048)
        }
        val e = extras("bomb", nextId(), thumb = httpsUrl("/bomb"))
        assertTrue(InstantPush.show(app, e, paced = false))
        InstantPush.attachPicture(app, e) // must not throw
        assertNotNull("the text stays", posted("bomb"))
    }

    @Test
    fun `undecodable bytes and a non-200 answer give null`() {
        bodies["/junk"] = ByteArray(5000) { 0x41 }
        assertNull(NotificationPicture.fetch(app, httpsUrl("/junk"), false, nextId()))
        assertNull(NotificationPicture.fetch(app, httpsUrl("/nothing-here"), false, nextId()))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }
}
