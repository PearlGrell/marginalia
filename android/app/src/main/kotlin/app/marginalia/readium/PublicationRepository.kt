package app.marginalia.readium

import android.content.Context
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.toUrl
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser

class OpenPublicationException(message: String) : Exception(message)

/**
 * Opens EPUB files with Readium and keeps them in memory, keyed by an id the Dart side holds,
 * until Dart closes them.
 */
class PublicationRepository(context: Context) {

    private val httpClient = DefaultHttpClient()
    private val assetRetriever = AssetRetriever(context.contentResolver, httpClient)
    private val publicationOpener = PublicationOpener(
        publicationParser = DefaultPublicationParser(
            context,
            httpClient = httpClient,
            assetRetriever = assetRetriever,
            pdfFactory = null,
        ),
    )

    private val publications = ConcurrentHashMap<String, Publication>()

    /** Opens the book at [path] just for [block], for example to read its metadata. */
    suspend fun <T> peek(path: String, block: suspend (Publication) -> T): T {
        val (id, publication) = open(path)
        try {
            return block(publication)
        } finally {
            close(id)
        }
    }

    suspend fun open(path: String): Pair<String, Publication> {
        val file = File(path)
        if (!file.exists()) throw OpenPublicationException("File not found: $path")

        val asset = assetRetriever.retrieve(file.toUrl(isDirectory = false))
            .getOrElse { throw OpenPublicationException("Can't read file: ${it.message}") }
        // Readium 3.3 ignores the constructor's onCreatePublication (open()'s parameter of the
        // same name shadows it), so the hook goes here.
        val publication = publicationOpener
            .open(asset, allowUserInteraction = false, onCreatePublication = { injectReaderStyles() })
            .getOrElse {
                asset.close()
                throw OpenPublicationException("Can't open publication: ${it.message}")
            }
        if (!publication.conformsTo(Publication.Profile.EPUB)) {
            publication.close()
            throw OpenPublicationException("Not an EPUB publication")
        }

        val id = UUID.randomUUID().toString()
        publications[id] = publication
        return id to publication
    }

    fun get(id: String): Publication? = publications[id]

    fun close(id: String) {
        publications.remove(id)?.close()
    }

    fun closeAll() {
        publications.values.forEach { it.close() }
        publications.clear()
    }
}

/** Summary of an opened publication, sent to Dart. */
@OptIn(ExperimentalReadiumApi::class)
fun Publication.toSummaryMap(id: String): Map<String, Any?> = mapOf(
    "id" to id,
    "title" to metadata.title,
    "authors" to metadata.authors.map { it.name },
    "language" to metadata.languages.firstOrNull(),
    "readingProgression" to metadata.readingProgression?.value,
    "toc" to tableOfContents.map { it.toTocMap() },
)

/**
 * Readium positions (about one per 1,024 characters) per chapter, for page counts and time
 * left: `{href, start, count}` with `start` the chapter's first position number.
 */
suspend fun Publication.chapterPositions(): List<Map<String, Any?>> {
    var start = 1
    return positionsByReadingOrder().mapIndexed { index, positions ->
        val chapter = mapOf(
            "href" to readingOrder[index].url().toString(),
            "start" to start,
            "count" to positions.size,
        )
        start += positions.size
        chapter
    }
}

private fun Link.toTocMap(): Map<String, Any?> = mapOf(
    "title" to title,
    "href" to href.toString(),
    "children" to children.map { it.toTocMap() },
)
