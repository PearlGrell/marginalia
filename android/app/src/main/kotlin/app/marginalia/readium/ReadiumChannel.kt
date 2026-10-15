package app.marginalia.readium

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.content.Content
import org.readium.r2.shared.publication.services.content.content

/**
 * Publication-level calls from Dart: opening and closing books.
 * Navigation calls go to each reader view's own channel (see [ReaderPlatformView]).
 */
class ReadiumChannel(
    messenger: BinaryMessenger,
    private val repository: PublicationRepository,
) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("bad_args", "path is required", null)
                scope.launch {
                    try {
                        val summary = withContext(Dispatchers.IO) {
                            val (id, publication) = repository.open(path)
                            publication.toSummaryMap(id) +
                                ("chapters" to publication.chapterPositions())
                        }
                        result.success(summary)
                    } catch (e: OpenPublicationException) {
                        result.error("open_failed", e.message, null)
                    }
                }
            }
            "textRange" -> {
                // Part of the book's text, as it's read (the app keeps it, a page at a time):
                // after a place in one chapter, up to a place in another (reading-order
                // indexes and progressions), as [{chapter, progression, text}] by paragraph.
                val publication = call.argument<String>("id")?.let(repository::get)
                    ?: return result.error("bad_args", "The book is not open", null)
                val fromChapter = call.argument<Int>("fromChapter") ?: return result.error("bad_args", "fromChapter", null)
                val after = call.argument<Double>("afterProgression") ?: -1.0
                val toChapter = call.argument<Int>("toChapter") ?: fromChapter
                val upTo = call.argument<Double>("toProgression") ?: 1.0
                scope.launch {
                    result.success(withContext(Dispatchers.Default) { publication.textRange(fromChapter, after, toChapter, upTo) })
                }
            }
            "close" -> {
                call.argument<String>("id")?.let(repository::close)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    companion object {
        const val CHANNEL = "marginalia/readium"
    }
}

/**
 * The book's paragraphs after [afterProgression] in chapter [fromChapter], up to and including
 * [toProgression] in chapter [toChapter] (reading-order indexes), as `{chapter, progression, text}`.
 */
private suspend fun Publication.textRange(
    fromChapter: Int,
    afterProgression: Double,
    toChapter: Int,
    toProgression: Double,
): List<Map<String, Any?>> {
    if (fromChapter !in readingOrder.indices || toChapter < fromChapter) return emptyList()
    val order = readingOrder.map { it.url().removeFragment().toString() }
    val start = locatorFromLink(readingOrder[fromChapter]) ?: return emptyList()
    val iterator = content(start)?.iterator() ?: return emptyList()
    val kept = mutableListOf<Map<String, Any?>>()
    while (true) {
        val element = iterator.nextOrNull() ?: break
        val chapter = order.indexOf(element.locator.href.removeFragment().toString())
        if (chapter < fromChapter) continue
        if (chapter > toChapter) break
        val progression = element.locator.locations.progression ?: 0.0
        if (chapter == fromChapter && progression <= afterProgression) continue
        if (chapter == toChapter && progression > toProgression) break
        val text = (element as? Content.TextualElement)?.text?.trim()
        if (text.isNullOrEmpty()) continue
        kept += mapOf("chapter" to chapter, "progression" to progression, "text" to text)
    }
    return kept
}
