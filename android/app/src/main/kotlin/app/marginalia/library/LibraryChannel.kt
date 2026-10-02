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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> pickFiles(result)
            "pickFolder" -> pickFolder(result)
            "pickCover" -> {
                val bookId = call.argument<String>("bookId")
                    ?: return result.error("bad_args", "bookId is required", null)
                pickCover(bookId, result)
            }
            "scanFolder" -> {
                val uri = call.argument<String>("uri")
                    ?: return result.error("bad_args", "uri is required", null)
                scope.launch {
                    try {
                        result.success(withContext(Dispatchers.IO) { scanFolder(Uri.parse(uri)) })
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
        // Many file managers label EPUBs as generic binaries; the import checks each file.
        launcher.launch(arrayOf("application/epub+zip", "application/octet-stream"))
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

    /** Every EPUB under the tree, depth first. */
    private fun scanFolder(tree: Uri): List<Map<String, Any?>> {
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
            resolver.query(children, columns, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0)
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)
                    when {
                        mime == DocumentsContract.Document.MIME_TYPE_DIR -> pending.add(id)
                        mime == "application/epub+zip" || name.endsWith(".epub", ignoreCase = true) ->
                            found += mapOf(
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                                "name" to name,
                                "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
                                "modified" to if (cursor.isNull(4)) null else cursor.getLong(4),
                            )
                    }
                }
            }
        }
        return found
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}

/**
 * Copies a book into app storage as `library/<sha256>.epub` and reads what the library shows:
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
        val temp = File(staging, "import-${UUID.randomUUID()}.epub")
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
        val target = File(libraryDir, "$id.epub")
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
