package app.marginalia

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The reading companion's model: Gemini Nano, the phone's own (Android AICore, through ML
 * Kit's Prompt API). Nothing leaves the phone, and there's nothing for the app to download:
 * on phones that have it, the system fetches it once.
 *
 * `marginalia/companion`:
 * - `status` → "available", "downloadable", "downloading" or "unavailable"
 * - `download` → true once it's ready (progress as `onDownloadProgress {bytes}`)
 * - `generate {prompt}` → the answer's text
 */
class CompanionChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, "marginalia/companion").also { it.setMethodCallHandler(this) }

    /** Made on first use: on phones without AICore, getting it at all can fail. */
    private val model by lazy { Generation.getClient() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> scope.launch {
                val status = runCatching { model.checkStatus() }.getOrNull()
                result.success(
                    when (status) {
                        FeatureStatus.AVAILABLE -> "available"
                        FeatureStatus.DOWNLOADABLE -> "downloadable"
                        FeatureStatus.DOWNLOADING -> "downloading"
                        else -> "unavailable"
                    },
                )
            }
            "download" -> scope.launch {
                try {
                    var ready = false
                    model.download().collect { status ->
                        when (status) {
                            is DownloadStatus.DownloadProgress ->
                                channel.invokeMethod("onDownloadProgress", mapOf("bytes" to status.totalBytesDownloaded))
                            DownloadStatus.DownloadCompleted -> ready = true
                            else -> {}
                        }
                    }
                    result.success(ready)
                } catch (e: Exception) {
                    result.error("download_failed", e.message, null)
                }
            }
            "generate" -> {
                val prompt = call.argument<String>("prompt") ?: return result.error("bad_args", "prompt", null)
                scope.launch {
                    try {
                        val response = model.generateContent(prompt)
                        result.success(response.candidates.firstOrNull()?.text.orEmpty())
                    } catch (e: Exception) {
                        result.error("generate_failed", e.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }
}
