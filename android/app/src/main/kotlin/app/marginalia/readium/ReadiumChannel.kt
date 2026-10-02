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
