package app.marginalia

import android.content.Context
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.PromptTemplates
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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The reading companion's models. Gemini Nano, the phone's own (Android AICore, through ML
 * Kit's Prompt API), where the phone has it: the system fetches it once. Elsewhere Gemma 3 1B,
 * run with MediaPipe's LLM Inference from a .task file the app downloads (see `gemma.dart`).
 * Nothing leaves the phone.
 *
 * `marginalia/companion`:
 * - `status` → Nano's: "available", "downloadable", "downloading" or "unavailable"
 * - `download` → true once Nano is ready (progress as `onDownloadProgress {bytes}`)
 * - `generate {prompt}` → Nano's answer
 * - `gemmaChat {id, path, prompt, fresh, maxTokens}` → Gemma's answer, at most [maxTokens] long, from the model at [path], in the
 *   conversation so far (or a new one, `fresh`), written as it goes (`onGemmaText {id, text}`,
 *   the text so far); error `context_full` when the conversation has no room left for it
 * - `gemmaOnce {path, prompt, maxTokens}` → Gemma's answer, outside the conversation (it's left as it was)
 * - `gemmaJanky` the screen stuttered while Gemma wrote: if that was on the GPU, the CPU next time
 * - `gemmaCancel` stops the answer being written (a newer question, or the sheet closed)
 * - `gemmaClose` → lets go of Gemma (before its file is removed)
 */
class CompanionChannel(messenger: BinaryMessenger, private val context: Context) : MethodChannel.MethodCallHandler {

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
                    var failure: String? = null
                    model.download().collect { status ->
                        when (status) {
                            is DownloadStatus.DownloadProgress ->
                                channel.invokeMethod("onDownloadProgress", mapOf("bytes" to status.totalBytesDownloaded))
                            DownloadStatus.DownloadCompleted -> ready = true
                            is DownloadStatus.DownloadFailed -> failure = status.e.message
                            else -> {}
                        }
                    }
                    if (failure != null) result.error("download_failed", failure, null) else result.success(ready)
                } catch (e: Exception) {
                    result.error("download_failed", e.message, null)
                }
            }
            "gemmaChat" -> {
                val path = call.argument<String>("path") ?: return result.error("bad_args", "path", null)
                val prompt = call.argument<String>("prompt") ?: return result.error("bad_args", "prompt", null)
                val fresh = call.argument<Boolean>("fresh") ?: true
                val id = call.argument<Int>("id") ?: 0
                val maxTokens = call.argument<Int>("maxTokens") ?: DEFAULT_ANSWER
                scope.launch {
                    try {
                        val answer = gemmaChat(path, prompt, fresh, maxTokens) { text ->
                            main.post { channel.invokeMethod("onGemmaText", mapOf("id" to id, "text" to text)) }
                        }
                        result.success(answer)
                    } catch (e: ContextFull) {
                        result.error("context_full", e.message, null)
                    } catch (e: Throwable) {
                        // Native errors too (a model that won't load): said, not swallowed.
                        android.util.Log.e("Companion", "Gemma failed", e)
                        result.error("generate_failed", e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
            "gemmaOnce" -> {
                val path = call.argument<String>("path") ?: return result.error("bad_args", "path", null)
                val prompt = call.argument<String>("prompt") ?: return result.error("bad_args", "prompt", null)
                val maxTokens = call.argument<Int>("maxTokens") ?: DEFAULT_ANSWER
                scope.launch {
                    try {
                        result.success(gemmaOnce(path, prompt, maxTokens))
                    } catch (e: Throwable) {
                        android.util.Log.e("Companion", "Gemma failed", e)
                        result.error("generate_failed", e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
            "gemmaJanky" -> {
                val path = gemmaPath
                if (path != null && gemmaBackend == LlmInference.Backend.GPU) {
                    // Rendering and Gemma share the GPU on this phone: the CPU from the next load.
                    android.util.Log.i("Companion", "Gemma on the GPU makes the screen stutter here: the CPU next time")
                    java.io.File(java.io.File(path).parentFile, "gemma-speed-GPU").writeText("0.0")
                }
                result.success(null)
            }
            "gemmaCancel" -> {
                // Not behind the lock: the answer being written holds it.
                cancelled = true
                runCatching { chat?.cancelGenerateResponseAsync() }
                result.success(null)
            }
            "gemmaClose" -> scope.launch {
                gemmaLock.withLock { closeGemma() }
                result.success(null)
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

    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    /** Loaded on first use (a few seconds) and kept: one question at a time. */
    private var gemma: LlmInference? = null
    private var gemmaPath: String? = null
    private var gemmaBackend: LlmInference.Backend? = null
    private val gemmaLock = Mutex()

    /** The conversation: Gemma keeps what it has read, so a follow-up reads only what's new. */
    private var chat: LlmInferenceSession? = null
    private var chatTokens = 0

    /** Set by `gemmaCancel`: the answer stopping isn't a failure. */
    @Volatile private var cancelled = false

    private class ContextFull : Exception("The conversation is full")

    /**
     * Gemma, loaded where it writes fastest on this phone: the GPU to start with, the CPU too if
     * the GPU turns out slow (on some phones it reads faster but writes slower), then whichever
     * wrote faster (see [noteSpeed]). A GPU driver that can't run it may take the app down rather
     * than fail, so trying it is marked on disk first: if the app dies there, it's the CPU.
     */
    private fun loadGemma(path: String): LlmInference {
        gemma?.takeIf { gemmaPath == path }?.let { return it }
        closeGemma()
        val dir = java.io.File(path).parentFile
        val choice = java.io.File(dir, "gemma-backend")
        val trying = java.io.File(dir, "gemma-gpu-trying")
        if (trying.exists()) {
            // The app ended while trying the GPU.
            choice.writeText("CPU")
            trying.delete()
        }
        val gpu = speed(dir, LlmInference.Backend.GPU)
        val cpu = speed(dir, LlmInference.Backend.CPU)
        val order = when {
            choice.takeIf { it.exists() }?.readText()?.trim() == "CPU" -> listOf(LlmInference.Backend.CPU)
            gpu == null -> listOf(LlmInference.Backend.GPU, LlmInference.Backend.CPU)
            // Slow on the GPU and not yet timed on the CPU: time it there.
            cpu == null && gpu < SLOW -> listOf(LlmInference.Backend.CPU, LlmInference.Backend.GPU)
            cpu != null && cpu > gpu -> listOf(LlmInference.Backend.CPU, LlmInference.Backend.GPU)
            else -> listOf(LlmInference.Backend.GPU, LlmInference.Backend.CPU)
        }
        var failure: Throwable? = null
        for (backend in order) {
            try {
                if (backend == LlmInference.Backend.GPU) trying.writeText("1")
                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(path)
                    .setMaxTokens(MAX_TOKENS)
                    .setPreferredBackend(backend)
                    .build()
                val model = LlmInference.createFromOptions(context, options)
                gemma = model
                gemmaPath = path
                gemmaBackend = backend
                return model
            } catch (e: Throwable) {
                android.util.Log.w("Companion", "Gemma on $backend failed: ${e.message}")
                trying.delete()
                choice.writeText("CPU")
                failure = e
            }
        }
        throw failure ?: IllegalStateException("Gemma couldn't start")
    }

    /** How fast Gemma wrote on [backend] here, in tokens a second; null if never timed. */
    private fun speed(dir: java.io.File?, backend: LlmInference.Backend): Double? =
        java.io.File(dir, "gemma-speed-$backend").takeIf { it.exists() }?.readText()?.trim()?.toDoubleOrNull()

    /** Notes how fast Gemma wrote an answer of [tokens] in [nanos] (longer answers count). */
    private fun noteSpeed(path: String, tokens: Int, nanos: Long) {
        val backend = gemmaBackend ?: return
        if (tokens < 20 || nanos <= 0) return
        java.io.File(java.io.File(path).parentFile, "gemma-speed-$backend").writeText("${tokens / (nanos / 1e9)}")
    }

    /** The first answer settles where Gemma runs. */
    private fun settleBackend(path: String, worked: Boolean) {
        val dir = java.io.File(path).parentFile
        java.io.File(dir, "gemma-gpu-trying").delete()
        if (gemmaBackend == LlmInference.Backend.GPU || !worked) {
            java.io.File(dir, "gemma-backend").writeText(if (worked) "GPU" else "CPU")
        }
    }

    private fun newChat(model: LlmInference) {
        runCatching { chat?.close() }
        chatTokens = 0
        chat = LlmInferenceSession.createFromOptions(model, sessionOptions())
    }

    /** A question on its own, in a session of its own: the conversation is left as it was. */
    private suspend fun gemmaOnce(path: String, prompt: String, maxTokens: Int): String = gemmaLock.withLock {
        withContext(Dispatchers.Default) {
            val started = System.nanoTime()
            cancelled = false
            LlmInferenceSession.createFromOptions(loadGemma(path), sessionOptions()).use { session ->
                val (answer, _) = write(session, prompt, maxTokens) {}
                // Not timed for speed: this time includes reading the prompt (see [noteSpeed]).
                android.util.Log.i(
                    "Companion",
                    "Gemma on $gemmaBackend, once: ${session.sizeInTokens(prompt)} tokens in, " +
                        "${session.sizeInTokens(answer)} out, ${(System.nanoTime() - started) / 1_000_000} ms",
                )
                answer.trim()
            }
        }
    }

    private fun sessionOptions() =
            LlmInferenceSession.LlmInferenceSessionOptions.builder()
                // Cool: it keeps to the passages it's given instead of making things up.
                .setTemperature(0.3f)
                .setTopK(40)
                .setTopP(0.9f)
                // Gemma's chat turns: without them it carries on the prompt rather than answering.
                .setPromptTemplates(
                    PromptTemplates.builder()
                        .setUserPrefix("<start_of_turn>user\n")
                        .setUserSuffix("<end_of_turn>\n")
                        .setModelPrefix("<start_of_turn>model\n")
                        .setModelSuffix("<end_of_turn>\n")
                        .build(),
                )
                .build()

    private suspend fun gemmaChat(path: String, prompt: String, fresh: Boolean, maxTokens: Int, onText: (String) -> Unit): String =
        gemmaLock.withLock {
            withContext(Dispatchers.Default) {
                cancelled = false
                try {
                    answer(loadGemma(path), path, prompt, fresh, maxTokens, onText)
                } catch (e: ContextFull) {
                    throw e
                } catch (e: Throwable) {
                    if (cancelled || gemmaBackend != LlmInference.Backend.GPU) throw e
                    // Loaded on the GPU but couldn't answer there: the CPU, from now on.
                    android.util.Log.w("Companion", "Gemma on the GPU couldn't answer: ${e.message}")
                    settleBackend(path, worked = false)
                    closeGemma()
                    answer(loadGemma(path), path, prompt, fresh = true, maxTokens, onText)
                }
            }
        }

    /**
     * Writes the answer to [prompt] in [session], telling [onText] the text so far, and stops it
     * once it's [maxTokens] long (MediaPipe has no limit per answer, and a small model can run
     * on for minutes, holding up everything after it): what was written by then is the answer.
     * Returns the answer and when its first word came (0 if none).
     */
    private fun write(session: LlmInferenceSession, prompt: String, maxTokens: Int, onText: (String) -> Unit): Pair<String, Long> {
        val text = StringBuilder()
        var firstWord = 0L
        var chunks = 0
        val capped = java.util.concurrent.atomic.AtomicBoolean(false)
        session.addQueryChunk(prompt)
        val writing = session.generateResponseAsync { partial, _ ->
            if (capped.get()) return@generateResponseAsync
            if (firstWord == 0L && partial.isNotEmpty()) firstWord = System.nanoTime()
            text.append(partial)
            onText(text.toString())
            if (++chunks % 12 == 0 && session.sizeInTokens(text.toString()) >= maxTokens) {
                capped.set(true)
                session.cancelGenerateResponseAsync()
            }
        }
        try {
            writing.get()
        } catch (e: Exception) {
            // Stopped for length: a normal answer. Stopped by the reader, or a failure: not.
            if (!capped.get() || cancelled) throw e
        }
        return text.toString() to firstWord
    }

    private fun answer(model: LlmInference, path: String, prompt: String, fresh: Boolean, maxTokens: Int, onText: (String) -> Unit): String {
        if (fresh || chat == null) newChat(model)
        val session = chat!!
        val tokens = session.sizeInTokens(prompt)
        if (!fresh && chatTokens + tokens + ANSWER_ROOM > MAX_TOKENS) throw ContextFull()
        val started = System.nanoTime()
        val (answer, firstWord) = write(session, prompt, maxTokens, onText)
        chatTokens += tokens + session.sizeInTokens(answer) + 8
        if (firstWord > 0) noteSpeed(path, session.sizeInTokens(answer), System.nanoTime() - firstWord)
        android.util.Log.i(
            "Companion",
            "Gemma on $gemmaBackend: $tokens tokens in, ${session.sizeInTokens(answer)} out, " +
                "first word at ${(firstWord - started) / 1_000_000} ms, all in ${(System.nanoTime() - started) / 1_000_000} ms " +
                "(conversation $chatTokens)",
        )
        settleBackend(path, worked = true)
        return answer.trim().ifBlank { throw IllegalStateException("Gemma gave an empty answer") }
    }

    private fun closeGemma() {
        runCatching { chat?.close() }
        chat = null
        chatTokens = 0
        runCatching { gemma?.close() }
        gemma = null
        gemmaPath = null
        gemmaBackend = null
    }

    private companion object {
        /** The model's window (gemma3-1b-it-int4.task): prompt and answer together. */
        const val MAX_TOKENS = 2048

        /** Kept free in the conversation for the answer. */
        const val ANSWER_ROOM = 450

        /** An answer's length when the caller doesn't say. */
        const val DEFAULT_ANSWER = 200

        /** Writing slower than this (tokens a second) on the GPU, the CPU is worth a try. */
        const val SLOW = 8.0
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
        closeGemma()
    }
}
