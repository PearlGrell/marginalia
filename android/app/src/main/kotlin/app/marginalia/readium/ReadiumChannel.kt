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
            "textUpTo" -> {
                // The book's text from the start to a place (never past it: no spoilers),
                // keeping the last maxChars of it: [{chapter, text}] by paragraph.
                val publication = call.argument<String>("id")?.let(repository::get)
                    ?: return result.error("bad_args", "The book is not open", null)
                val until = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
                    ?: return result.error("bad_args", "locator is invalid", null)
                val maxChars = call.argument<Int>("maxChars") ?: 400_000
                scope.launch {
                    result.success(withContext(Dispatchers.Default) { publication.textUpTo(until, maxChars) })
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
 * The book's paragraphs from its start up to [until] (not past it), as `{chapter, text}` with
 * the chapter's reading-order index; only the last [maxChars] of text are kept.
 */
private suspend fun Publication.textUpTo(until: Locator, maxChars: Int): List<Map<String, Any?>> {
    val order = readingOrder.map { it.url().removeFragment().toString() }
    val lastChapter = order.indexOf(until.href.removeFragment().toString())
    if (lastChapter < 0) return emptyList()
    val lastProgression = until.locations.progression ?: 0.0
    val iterator = content()?.iterator() ?: return emptyList()
    val kept = ArrayDeque<Pair<Int, String>>()
    var total = 0
    while (true) {
        val element = iterator.nextOrNull() ?: break
        val chapter = order.indexOf(element.locator.href.removeFragment().toString())
        if (chapter > lastChapter) break
        if (chapter == lastChapter && (element.locator.locations.progression ?: 0.0) > lastProgression) break
        val text = (element as? Content.TextualElement)?.text?.trim()
        if (text.isNullOrEmpty()) continue
        kept.addLast(chapter to text)
        total += text.length
        while (total > maxChars && kept.size > 1) total -= kept.removeFirst().second.length
    }
    return kept.map { (chapter, text) -> mapOf("chapter" to chapter, "text" to text) }
}
