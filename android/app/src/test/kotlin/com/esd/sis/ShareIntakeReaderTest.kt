package com.esd.sis

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.test.core.app.ApplicationProvider
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver

/**
 * Share into SIS, Android intake. Written from the contract, not the code:
 * - only content:// URIs of another app; refused: an authority holding '@', an authority
 *   starting with our package, a provider owned by our package (no known owner is accepted);
 * - at most 10 items; text cut to 4000 characters;
 * - photos shrunk to a 1600 px longest edge and kept in cache/shared; videos copied to
 *   cache/shared as .mp4 files; a copy that breaks halfway leaves no file behind;
 * - cleanStale removes cache/shared files and cache/picked_raw_ files older than 24 h, nothing else.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ShareIntakeReaderTest {
    /** Another app's files: names and types come from the URI's last segment. */
    class OtherFiles : ContentProvider() {
        override fun onCreate() = true
        override fun getType(uri: Uri): String? = when {
            uri.lastPathSegment!!.endsWith(".mp4") -> "video/mp4"
            uri.lastPathSegment!!.endsWith(".jpg") -> "image/jpeg"
            else -> null
        }
        override fun query(uri: Uri, p: Array<String>?, s: String?, a: Array<String>?, o: String?): Cursor =
            MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
                addRow(arrayOf<Any>(uri.lastPathSegment!!, 1L))
            }
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun delete(uri: Uri, s: String?, a: Array<String>?) = 0
        override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<String>?) = 0
    }

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val shared get() = File(context.cacheDir, "shared")
    private val other = "com.other.files"

    @Before
    fun providers() {
        Robolectric.setupContentProvider(OtherFiles::class.java, other)
        owner(other, "com.other")
        shared.deleteRecursively()
    }

    private fun owner(authority: String, pkg: String) {
        shadowOf(context.packageManager).addOrUpdateProvider(
            ProviderInfo().apply {
                this.authority = authority
                packageName = pkg
                name = OtherFiles::class.java.name
            },
        )
    }

    private fun jpeg(w: Int, h: Int): ByteArray {
        val out = ByteArrayOutputStream()
        Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.JPEG, 90, out)
        return out.toByteArray()
    }

    private fun serve(uri: Uri, bytes: ByteArray): Uri {
        shadowOf(context.contentResolver).registerInputStream(uri, ByteArrayInputStream(bytes))
        return uri
    }

    private fun photo(authority: String = other, name: String = "p${System.nanoTime()}.jpg"): Uri =
        serve(Uri.parse("content://$authority/x/$name"), jpeg(40, 20))

    private fun send(vararg uris: Uri, text: String? = null): Intent =
        if (uris.size <= 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = "*/*"
                text?.let { putExtra(Intent.EXTRA_TEXT, it) }
                uris.firstOrNull()?.let { putExtra(Intent.EXTRA_STREAM, it) }
            }
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = "*/*"
                text?.let { putExtra(Intent.EXTRA_TEXT, it) }
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris.toList()))
            }
        }

    @Suppress("UNCHECKED_CAST")
    private fun items(read: Map<String, Any?>?): List<Map<String, Any?>> =
        (read?.get("items") as? List<Map<String, Any?>>) ?: emptyList()

    private fun readItems(vararg uris: Uri) = items(ShareIntakeReader(context).read(send(*uris)))

    @Test
    fun `only send and send-multiple are shares`() {
        val reader = ShareIntakeReader(context)
        assertTrue(reader.isShare(Intent(Intent.ACTION_SEND)))
        assertTrue(reader.isShare(Intent(Intent.ACTION_SEND_MULTIPLE)))
        assertFalse(reader.isShare(Intent(Intent.ACTION_VIEW)))
        assertFalse(reader.isShare(Intent(Intent.ACTION_MAIN)))
        assertFalse(reader.isShare(null))
    }

    @Test
    fun `text is kept and cut to 4000 characters`() {
        val reader = ShareIntakeReader(context)
        assertEquals("hello https://a.example", reader.read(send(text = "hello https://a.example"))!!["text"])
        assertEquals("x".repeat(4000), reader.read(send(text = "x".repeat(5000)))!!["text"])
        assertEquals("y".repeat(4000), reader.read(send(text = "y".repeat(4000)))!!["text"])
    }

    @Test
    fun `another app's photo is accepted, shrunk to 1600 px and kept in cache shared`() {
        val uri = serve(Uri.parse("content://$other/x/big.jpg"), jpeg(3200, 1000))
        val got = readItems(uri)
        assertEquals(1, got.size)
        assertEquals(false, got[0]["video"])
        val file = File(got[0]["path"] as String)
        assertEquals(shared.canonicalPath, file.parentFile!!.canonicalPath)
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, o)
        assertEquals(1600, maxOf(o.outWidth, o.outHeight))
        assertEquals(500, minOf(o.outWidth, o.outHeight))
    }

    @Test
    fun `a video is copied whole into cache shared as mp4`() {
        val bytes = ByteArray(200_000) { (it % 251).toByte() }
        val uri = serve(Uri.parse("content://$other/x/clip.mp4"), bytes)
        val got = readItems(uri)
        assertEquals(1, got.size)
        assertEquals(true, got[0]["video"])
        assertEquals("clip.mp4", got[0]["name"])
        val file = File(got[0]["path"] as String)
        assertEquals(shared.canonicalPath, file.parentFile!!.canonicalPath)
        assertTrue(file.name.endsWith(".mp4"))
        assertTrue(bytes.contentEquals(file.readBytes()))
    }

    @Test
    fun `a video copy that breaks halfway leaves no file and no item`() {
        val uri = Uri.parse("content://$other/x/broken.mp4")
        val breaking = object : InputStream() {
            var n = 0
            override fun read(): Int = if (n++ < 100_000) 7 else throw IOException("gone")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (n >= 100_000) throw IOException("gone")
                val k = minOf(len, 100_000 - n)
                b.fill(7, off, off + k)
                n += k
                return k
            }
        }
        shadowOf(context.contentResolver).registerInputStream(uri, breaking)
        val got = try {
            readItems(uri)
        } catch (e: Exception) {
            emptyList()
        }
        assertTrue(got.isEmpty())
        assertTrue(shared.listFiles().orEmpty().none { it.name.endsWith(".mp4") })
    }

    @Test
    fun `at most 10 items are taken`() {
        val uris = (1..12).map { photo(name = "m$it.jpg") }.toTypedArray()
        assertEquals(10, readItems(*uris).size)
    }

    @Test
    fun `a non-content uri is refused`() {
        val f = File(context.filesDir, "secret.jpg").apply { writeBytes(jpeg(10, 10)) }
        assertTrue(readItems(Uri.fromFile(f)).isEmpty())
        // Same authority as an accepted provider, only the scheme differs.
        assertTrue(readItems(serve(Uri.parse("file://$other/x/s.jpg"), jpeg(10, 10))).isEmpty())
        assertTrue(readItems(serve(Uri.parse("android.resource://$other/x/r.jpg"), jpeg(10, 10))).isEmpty())
    }

    @Test
    fun `an authority holding an at sign is refused even when another app owns it`() {
        val authority = "0@$other"
        Robolectric.setupContentProvider(OtherFiles::class.java, authority)
        owner(authority, "com.other")
        assertTrue(readItems(photo(authority)).isEmpty())
    }

    @Test
    fun `an authority starting with our package is refused even when another app owns it`() {
        val authority = "${context.packageName}.files"
        Robolectric.setupContentProvider(OtherFiles::class.java, authority)
        owner(authority, "com.other")
        assertTrue(readItems(photo(authority)).isEmpty())
    }

    @Test
    fun `a provider our own package owns is refused`() {
        val authority = "org.mine.files"
        Robolectric.setupContentProvider(OtherFiles::class.java, authority)
        owner(authority, context.packageName)
        assertTrue(readItems(photo(authority)).isEmpty())
    }

    @Test
    fun `a provider with no known owner is accepted`() {
        // Package visibility hides most providers: the resolver serves it, the package manager does not know it.
        Robolectric.setupContentProvider(OtherFiles::class.java, "org.hidden.files")
        assertNull(context.packageManager.resolveContentProvider("org.hidden.files", 0))
        assertEquals(1, readItems(photo("org.hidden.files")).size)
    }

    @Test
    fun `refused and accepted items mixed, only the accepted arrive`() {
        val got = readItems(photo("0@$other"), photo(), photo("${context.packageName}.x"))
        assertEquals(1, got.size)
    }

    @Test
    fun `cleanStale removes day-old shared and picked_raw files only`() {
        shared.mkdirs()
        val old = System.currentTimeMillis() - 25L * 60 * 60 * 1000
        val fresh = System.currentTimeMillis() - 23L * 60 * 60 * 1000
        fun file(dir: File, name: String, at: Long) = File(dir, name).apply { writeText("x"); setLastModified(at) }
        val oldShared = file(shared, "share-old.jpg", old)
        val freshShared = file(shared, "share-new.jpg", fresh)
        val oldRaw = file(context.cacheDir, "picked_raw_1", old)
        val freshRaw = file(context.cacheDir, "picked_raw_2", fresh)
        val oldOther = file(context.cacheDir, "keep_me", old)
        ShareIntakeReader(context).cleanStale()
        assertFalse(oldShared.exists())
        assertFalse(oldRaw.exists())
        assertTrue(freshShared.exists())
        assertTrue(freshRaw.exists())
        assertTrue(oldOther.exists())
    }
}
