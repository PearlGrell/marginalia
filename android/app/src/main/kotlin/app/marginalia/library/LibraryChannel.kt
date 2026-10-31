package app.marginalia.library

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.palette.graphics.Palette
import app.marginalia.readium.OpenPublicationException
import app.marginalia.readium.PublicationRepository
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.r2.shared.publication.services.cover

/**
 * Getting books into the library (`marginalia/library`):
 * - `pickFiles` → list of document URIs (the Android file picker, several at once)
 * - `pickFolder` → a folder (tree) URI, with read permission kept across restarts
 * - `scanFolder {uri}` → `[{uri, name, size, modified}]` for every EPUB in the folder and
 *   its subfolders (it fails if access to the folder was lost)
 * - `importFile {uri}` → copies the file into the library under its SHA-256 fingerprint and
 *   returns its metadata (see [BookImporter])
 * - `pickCover {bookId}` → lets the reader pick an image and saves it as the book's cover:
 *   `{coverPath, coverColor}`, or null if nothing was picked
 * - `scanFolder {uri, opf: true}` → the same, each with `opf`: the text of the
 *   `metadata.opf` beside it, if any (a Calibre library keeps one in each book's folder)
 * - `pickTextFile` → the text of a file the reader picks (a Kindle's My Clippings.txt), or
 *   null if nothing was picked
 * - `takeOpenedFile` → `{uri, name}` of a book another app asked to open, once, or null.
 *   Dart is told with `onFileOpened` when one arrives.
 */
class LibraryChannel(
    messenger: BinaryMessenger,
    private val activity: FragmentActivity,
    repository: PublicationRepository,
) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, "marginalia/library").also {
        it.setMethodCallHandler(this)
    }
    private val importer = BookImporter(activity.applicationContext, repository)
    private val requestCount = AtomicInteger()

    /** A book another app asked to open, until Dart takes it. */
    private var openedFile: Map<String, String>? = null

    /** Another app asked to open [uri] ("Open with Marginalia"). */
    fun opened(uri: Uri) {
        val name = runCatching {
            activity.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull() ?: uri.lastPathSegment ?: "Book"
        openedFile = mapOf("uri" to uri.toString(), "name" to name)
        channel.invokeMethod("onFileOpened", null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> pickFiles(result)
            "takeOpenedFile" -> {
                result.success(openedFile)
                openedFile = null
            }
            "pickFolder" -> pickFolder(result)
            "pickTextFile" -> pickTextFile(result)
            "pickCover" -> {
                val bookId = call.argument<String>("bookId")
                    ?: return result.error("bad_args", "bookId is required", null)
                pickCover(bookId, result)
            }
            "scanFolder" -> {
                val uri = call.argument<String>("uri")
                    ?: return result.error("bad_args", "uri is required", null)
                val opf = call.argument<Boolean>("opf") == true
                scope.launch {
                    try {
                        result.success(withContext(Dispatchers.IO) { scanFolder(Uri.parse(uri), opf) })
                    } catch (e: Exception) {
                        result.error("scan_failed", e.message, null)
                    }
                }
            }
            "importFile" -> {
                val uri = call.argument<String>("uri")
                    ?: return result.error("bad_args", "uri is required", null)
                scope.launch {
                    try {
                        result.success(importer.import(Uri.parse(uri)))
                    } catch (e: OpenPublicationException) {
                        result.error("not_a_book", e.message, null)
                    } catch (e: Exception) {
                        result.error("import_failed", e.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFiles(result: MethodChannel.Result) {
        val key = "marginalia-pick-files-${requestCount.incrementAndGet()}"
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<Array<String>>
        launcher = activity.activityResultRegistry.register(
            key,
            ActivityResultContracts.OpenMultipleDocuments(),
        ) { uris ->
            launcher.unregister()
            result.success(uris.map { it.toString() })
        }
        // Many file managers label books as generic binaries; the import checks each file.
        launcher.launch(BOOK_TYPES)
    }

    private fun pickTextFile(result: MethodChannel.Result) {
        val key = "marginalia-pick-text-${requestCount.incrementAndGet()}"
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<Array<String>>
        launcher = activity.activityResultRegistry.register(
            key,
            ActivityResultContracts.OpenDocument(),
        ) { uri ->
            launcher.unregister()
            if (uri == null) return@register result.success(null)
            scope.launch {
                try {
                    val text = withContext(Dispatchers.IO) {
                        activity.contentResolver.openInputStream(uri)?.use { input ->
                            // Clippings files grow for years, but not past this.
                            String(input.readNBytesCompat(MAX_TEXT_BYTES), Charsets.UTF_8)
                        }
                    }
                    result.success(text)
                } catch (e: Exception) {
                    result.error("read_failed", e.message, null)
                }
            }
        }
        // A Kindle's file can be labelled anything by the file manager it comes through.
        launcher.launch(arrayOf("text/plain", "text/*", "application/octet-stream"))
    }

    private fun pickFolder(result: MethodChannel.Result) {
        val key = "marginalia-pick-folder-${requestCount.incrementAndGet()}"
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<Uri?>
        launcher = activity.activityResultRegistry.register(
            key,
            ActivityResultContracts.OpenDocumentTree(),
        ) { uri ->
            launcher.unregister()
            if (uri != null) {
                // Keep access, for re-scanning the folder later.
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            result.success(uri?.toString())
        }
        launcher.launch(null)
    }

    private fun pickCover(bookId: String, result: MethodChannel.Result) {
        val key = "marginalia-pick-cover-${requestCount.incrementAndGet()}"
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<String>
        launcher = activity.activityResultRegistry.register(
            key,
            ActivityResultContracts.GetContent(),
        ) { uri ->
            launcher.unregister()
            if (uri == null) return@register result.success(null)
            scope.launch {
                try {
                    result.success(importer.saveCustomCover(uri, bookId))
                } catch (e: Exception) {
                    result.error("cover_failed", e.message, null)
                }
            }
        }
        launcher.launch("image/*")
    }

    /**
     * Every book under the tree, depth first; with [opf], each with the text of the
     * `metadata.opf` in its folder (Calibre's), if there is one.
     */
    private fun scanFolder(tree: Uri, opf: Boolean = false): List<Map<String, Any?>> {
        val resolver = activity.contentResolver
        val found = mutableListOf<Map<String, Any?>>()
        val pending = ArrayDeque<String>().apply { add(DocumentsContract.getTreeDocumentId(tree)) }
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        while (pending.isNotEmpty()) {
            val parent = pending.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
            val here = mutableListOf<Map<String, Any?>>()
            var opfId: String? = null
            resolver.query(children, columns, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)
                    when {
                        mime == DocumentsContract.Document.MIME_TYPE_DIR -> pending.add(id)
                        name.equals("metadata.opf", ignoreCase = true) -> opfId = id
                        mime in BOOK_TYPES.dropLast(1) || BOOK_EXTENSIONS.any { name.endsWith(it, ignoreCase = true) } ->
                            here += mapOf(
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                                "name" to name,
                                "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
                                "modified" to if (cursor.isNull(4)) null else cursor.getLong(4),
                            )
                    }
                }
            }
            val metadata = opfId?.takeIf { opf && here.isNotEmpty() }?.let { id ->
                runCatching {
                    resolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))?.use {
                        String(it.readNBytesCompat(MAX_TEXT_BYTES), Charsets.UTF_8)
                    }
                }.getOrNull()
            }
            found += if (metadata == null) here else here.map { it + ("opf" to metadata) }
        }
        return found
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}

/** What the file pickers offer and folder scans pick up: EPUB, PDF and comic archives. */
private val BOOK_TYPES = arrayOf(
    "application/epub+zip",
    "application/pdf",
    "application/vnd.comicbook+zip",
    "application/x-cbz",
    "application/octet-stream",
)
private val BOOK_EXTENSIONS = listOf(".epub", ".pdf", ".cbz")

/** The most of a text file read in (a clippings file, a metadata.opf). */
private const val MAX_TEXT_BYTES = 32 * 1024 * 1024

/** Up to [limit] bytes of the stream ([java.io.InputStream.readNBytes] needs Android 13). */
private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (out.size() < limit) {
        val read = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (read < 0) break
        out.write(buffer, 0, read)
    }
    return out.toByteArray()
}

/**
 * The extension for a book file, from its first bytes (names and labels can't be trusted):
 * "pdf", "epub" (a zip whose first entry says it's an EPUB) or "cbz" (any other zip).
 */
internal fun bookExtension(head: ByteArray): String? = when {
    head.size >= 4 && String(head, 0, 4, Charsets.ISO_8859_1) == "%PDF" -> "pdf"
    head.size >= 4 && head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte() ->
        if (String(head, Charsets.ISO_8859_1).contains("mimetypeapplication/epub+zip")) "epub" else "cbz"
    else -> null
}

/**
 * Copies a book into app storage as `library/<sha256>.<epub|pdf|cbz>` and reads what the library shows:
 * title, authors, language, description, series, and the cover (saved as
 * `covers/<sha256>.jpg`, with a tint color picked from it).
 */
class BookImporter(
    context: android.content.Context,
    private val repository: PublicationRepository,
) {
    private val resolver = context.contentResolver
    private val staging = context.cacheDir
    private val libraryDir = File(context.filesDir, "library").apply { mkdirs() }
    private val coversDir = File(context.filesDir, "covers").apply { mkdirs() }

    suspend fun import(uri: Uri): Map<String, Any?> = withContext(Dispatchers.IO) {
        val temp = File(staging, "import-${UUID.randomUUID()}")
        val digest = MessageDigest.getInstance("SHA-256")
        val size = try {
            val input = resolver.openInputStream(uri) ?: throw IllegalStateException("Can't read $uri")
            input.use { source ->
                temp.outputStream().use { sink ->
                    val buffer = ByteArray(DEFAULT_BUFFER)
                    var total = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                        sink.write(buffer, 0, read)
                        total += read
                    }
                    total
                }
            }
        } catch (e: Exception) {
            temp.delete()
            throw e
        }

        val id = digest.digest().joinToString("") { "%02x".format(it) }
        val head = ByteArray(64).let { buffer -> buffer.copyOf(temp.inputStream().use { it.read(buffer) }.coerceAtLeast(0)) }
        val extension = bookExtension(head) ?: run {
            temp.delete()
            throw OpenPublicationException("Not a book this app can open")
        }
        val target = File(libraryDir, "$id.$extension")
        if (target.exists()) temp.delete() else if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = true)
            temp.delete()
        }

        val metadata = try {
            readMetadata(target, id)
        } catch (e: OpenPublicationException) {
            target.delete()
            throw e
        }
        metadata + mapOf(
            "id" to id,
            "path" to target.absolutePath,
            "fileSize" to size,
        )
    }

    private suspend fun readMetadata(file: File, id: String): Map<String, Any?> =
        repository.peek(file.absolutePath) { publication ->
            val metadata = publication.metadata
            val series = metadata.belongsToSeries.firstOrNull()
            val cover = publication.cover()?.let { saveCover(it, id) }
            mapOf(
                "title" to metadata.title?.takeIf { it.isNotBlank() },
                "authors" to metadata.authors.map { it.name }.filter { it.isNotBlank() },
                "language" to metadata.languages.firstOrNull(),
                "description" to metadata.description,
                "series" to series?.name?.takeIf { it.isNotBlank() },
                "seriesIndex" to series?.position,
                "coverPath" to cover?.first,
                "coverColor" to cover?.second,
            )
        }

    /** An image the reader picked, saved as the book's cover. */
    suspend fun saveCustomCover(uri: Uri, id: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        // Decode at about cover size, however large the picked image is.
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (bounds.outHeight / (sample * 2) >= COVER_HEIGHT) sample *= 2
        val bitmap = resolver.openInputStream(uri)?.use {
            android.graphics.BitmapFactory.decodeStream(
                it,
                null,
                android.graphics.BitmapFactory.Options().apply { inSampleSize = sample },
            )
        } ?: throw IllegalStateException("That image couldn't be read")
        val (path, color) = saveCover(bitmap, "$id-${System.currentTimeMillis()}")
        bitmap.recycle()
        mapOf("coverPath" to path, "coverColor" to color)
    }

    /** Saves a library-sized JPEG of the cover; returns its path and a tint color. */
    private fun saveCover(bitmap: Bitmap, id: String): Pair<String, Int?> {
        val scale = (COVER_HEIGHT.toFloat() / bitmap.height).coerceAtMost(1f)
        val scaled = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                bitmap,
                (bitmap.width * scale).toInt().coerceAtLeast(1),
                COVER_HEIGHT,
                true,
            )
        } else {
            bitmap
        }
        val file = File(coversDir, "$id.jpg")
        file.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 88, it) }

        val palette = Palette.from(scaled).maximumColorCount(16).generate()
        val swatch = palette.darkMutedSwatch ?: palette.mutedSwatch ?: palette.dominantSwatch
        if (scaled !== bitmap) scaled.recycle()
        return file.absolutePath to swatch?.rgb
    }

    companion object {
        private const val DEFAULT_BUFFER = 64 * 1024
        private const val COVER_HEIGHT = 900
    }
}
