package app.marginalia.listen

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import java.io.File
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.readium.navigator.media.tts.TtsEngine
import org.readium.navigator.media.tts.TtsEngineProvider
import org.readium.r2.navigator.preferences.PreferencesEditor
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.content.Content
import org.readium.r2.shared.publication.services.content.TextContentTokenizer
import org.readium.r2.shared.publication.services.content.content
import org.readium.r2.shared.util.Language
import org.readium.r2.shared.util.Try
import org.readium.r2.shared.util.tokenizer.DefaultTextContentTokenizer
import org.readium.r2.shared.util.tokenizer.TextUnit
import org.readium.r2.shared.util.tokenizer.Tokenizer

/**
 * Kokoro, a natural-sounding neural voice model, running on the phone with sherpa-onnx. The
 * model (kokoro-int8-multi-lang-v1_0, about 330 MB unpacked) is downloaded from Settings →
 * Downloads into [dir]; until then Listen uses the phone's own voices.
 */
object Kokoro {
    const val MODEL = "kokoro-int8-multi-lang-v1_0"

    /** Kokoro's voices, by speaker id (from the model's metadata). */
    val speakers = listOf(
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis", "ef_dora", "em_alex", "ff_siwis", "hf_alpha",
        "hf_beta", "hm_omega", "hm_psi", "if_sara", "im_nicola", "jf_alpha", "jf_gongitsune", "jf_nezumi",
        "jf_tebukuro", "jm_kumo", "pf_dora", "pm_alex", "pm_santa", "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao",
        "zf_xiaoyi", "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang", "em_santa",
    )

    /** The language a speaker speaks, from the first letter of its name. */
    fun languageOf(speaker: Int): String = when (speakers.getOrNull(speaker)?.first()) {
        'a' -> "en-US"
        'b' -> "en-GB"
        'e' -> "es"
        'f' -> "fr"
        'h' -> "hi"
        'i' -> "it"
        'j' -> "ja"
        'p' -> "pt-BR"
        'z' -> "zh"
        else -> "en"
    }

    /** Book languages Kokoro can read. */
    fun supports(language: String?): Boolean =
        language?.substringBefore('-')?.substringBefore('_')?.lowercase() in setOf("en", "es", "fr", "hi", "it", "ja", "pt", "zh")

    /** The voice for a book in [language] when none was chosen. */
    fun defaultSpeaker(language: String?): Int {
        val lang = language?.lowercase().orEmpty()
        return when {
            lang.startsWith("en-gb") || lang.startsWith("en_gb") -> speakers.indexOf("bf_emma")
            lang.startsWith("es") -> speakers.indexOf("ef_dora")
            lang.startsWith("fr") -> speakers.indexOf("ff_siwis")
            lang.startsWith("hi") -> speakers.indexOf("hf_alpha")
            lang.startsWith("it") -> speakers.indexOf("if_sara")
            lang.startsWith("ja") -> speakers.indexOf("jf_alpha")
            lang.startsWith("pt") -> speakers.indexOf("pf_dora")
            lang.startsWith("zh") -> speakers.indexOf("zf_xiaobei")
            else -> speakers.indexOf("am_liam")
        }
    }

    fun dir(context: Context) = File(context.filesDir, "kokoro/$MODEL")

    fun isInstalled(context: Context): Boolean {
        val dir = dir(context)
        return listOf("model.int8.onnx", "voices.bin", "tokens.txt").all { File(dir, it).isFile } &&
            File(dir, "espeak-ng-data").isDirectory
    }

    /**
     * Loads the model for reading in [language] (espeak-ng handles languages other than
     * English and Chinese, so the model is set up per language). Takes a second or two.
     */
    fun load(context: Context, language: String?): OfflineTts {
        val d = dir(context).absolutePath
        val lang = language?.lowercase().orEmpty()
        val espeak = when {
            lang.startsWith("es") -> "es"
            lang.startsWith("fr") -> "fr"
            lang.startsWith("hi") -> "hi"
            lang.startsWith("it") -> "it"
            lang.startsWith("ja") -> "ja"
            lang.startsWith("pt") -> "pt-br"
            else -> ""
        }
        val british = lang.startsWith("en-gb") || lang.startsWith("en_gb")
        val lexicons = (if (british) listOf("lexicon-gb-en.txt", "lexicon-us-en.txt") else listOf("lexicon-us-en.txt", "lexicon-gb-en.txt")) +
            "lexicon-zh.txt"
        val config = OfflineTtsConfig(
            model = OfflineTtsModelConfig(
                kokoro = OfflineTtsKokoroModelConfig(
                    model = "$d/model.int8.onnx",
                    voices = "$d/voices.bin",
                    tokens = "$d/tokens.txt",
                    dataDir = "$d/espeak-ng-data",
                    lexicon = lexicons.filter { File(d, it).isFile }.joinToString(",") { "$d/$it" },
                    lang = espeak,
                    dictDir = "$d/dict",
                    lengthScale = 1.0f,
                ),
                numThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 4),
                debug = false,
                provider = "cpu",
            ),
            ruleFsts = listOf("phone-zh.fst", "date-zh.fst", "number-zh.fst")
                .filter { File(d, it).isFile }
                .joinToString(",") { "$d/$it" },
            maxNumSentences = 1,
        )
        return OfflineTts(assetManager = null, config = config)
    }
}

/** Plays mono float PCM, blocking until it has been heard. */
internal class PcmPlayer(sampleRate: Int) {
    private val track: AudioTrack = AudioTrack.Builder()
        .setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        .setAudioFormat(
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
        )
        .setBufferSizeInBytes(
            AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT) * 4,
        )
        .setTransferMode(AudioTrack.MODE_STREAM)
        .build()

    @Volatile private var stopped = false

    /** Returns false if stopped before the end. */
    suspend fun play(samples: FloatArray, isActive: () -> Boolean): Boolean {
        stopped = false
        track.play()
        val start = track.playbackHeadPosition
        var offset = 0
        val chunk = 4096
        while (offset < samples.size) {
            if (stopped || !isActive()) return false
            val n = track.write(samples, offset, minOf(chunk, samples.size - offset), AudioTrack.WRITE_BLOCKING)
            if (n <= 0) break
            offset += n
        }
        // Wait until the last of it has come out of the speaker.
        while (!stopped && isActive() && track.playbackHeadPosition - start < samples.size) {
            delay(20)
        }
        return !stopped
    }

    fun stop() {
        stopped = true
        runCatching {
            track.pause()
            track.flush()
        }
    }

    fun release() {
        stop()
        track.release()
    }
}

@OptIn(ExperimentalReadiumApi::class)
data class KokoroSettings(
    override val language: Language,
    override val overrideContentLanguage: Boolean = false,
    val speed: Double,
    val speaker: Int,
) : TtsEngine.Settings

@OptIn(ExperimentalReadiumApi::class)
data class KokoroPreferences(
    override val language: Language? = null,
    val speed: Double? = null,
    val speaker: Int? = null,
) : TtsEngine.Preferences<KokoroPreferences> {
    override fun plus(other: KokoroPreferences) = KokoroPreferences(
        language = other.language ?: language,
        speed = other.speed ?: speed,
        speaker = other.speaker ?: speaker,
    )
}

@OptIn(ExperimentalReadiumApi::class)
class KokoroPreferencesEditor(initial: KokoroPreferences) : PreferencesEditor<KokoroPreferences> {
    private var current = initial

    override val preferences: KokoroPreferences
        get() = current

    override fun clear() {
        current = KokoroPreferences()
    }
}

@OptIn(ExperimentalReadiumApi::class)
data class KokoroVoice(val speaker: Int, val name: String, override val language: Language) : TtsEngine.Voice

@OptIn(ExperimentalReadiumApi::class)
class KokoroError(override val message: String, override val cause: org.readium.r2.shared.util.Error? = null) :
    TtsEngine.Error

/**
 * Readium's text-to-speech engine, speaking with Kokoro. While a sentence plays, the next one
 * is already being synthesized ([Lookahead]), so reading flows without pauses between them.
 */
@OptIn(ExperimentalReadiumApi::class)
class KokoroEngine(
    private val tts: OfflineTts,
    private val publication: Publication,
    private val tokenizerFactory: (Language?) -> Tokenizer<String, IntRange>,
    private val currentLocator: () -> Locator?,
    initial: KokoroPreferences,
    private val defaultLanguage: Language,
) : TtsEngine<KokoroSettings, KokoroPreferences, KokoroError, KokoroVoice> {

    private val main = Handler(Looper.getMainLooper())

    /** sherpa-onnx isn't thread-safe: one synthesis at a time, on one thread. */
    private val synthesisThread = Executors.newSingleThreadExecutor()
    private val synthesis = synthesisThread.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob())
    private val player = PcmPlayer(tts.sampleRate())
    private val lookahead = Lookahead()

    private val _settings = MutableStateFlow(resolve(initial))
    override val settings: StateFlow<KokoroSettings> = _settings

    override val voices: Set<KokoroVoice> = Kokoro.speakers.indices
        .map { KokoroVoice(it, Kokoro.speakers[it], Language(Kokoro.languageOf(it))) }
        .toSet()

    private var listener: TtsEngine.Listener<KokoroError>? = null
    private var current: Pair<TtsEngine.RequestId, Job>? = null

    /** Audio ready or on its way, by [key]. */
    private val prepared = LinkedHashMap<String, Deferred<FloatArray>>()

    private fun resolve(p: KokoroPreferences) = KokoroSettings(
        language = p.language ?: defaultLanguage,
        speed = (p.speed ?: 1.0).coerceIn(0.5, 3.0),
        speaker = (p.speaker ?: Kokoro.defaultSpeaker(defaultLanguage.code)).coerceIn(0, Kokoro.speakers.lastIndex),
    )

    override fun submitPreferences(preferences: KokoroPreferences) {
        _settings.value = resolve(preferences)
    }

    override fun setListener(listener: TtsEngine.Listener<KokoroError>?) {
        this.listener = listener
    }

    private fun key(text: String) = "${_settings.value.speaker}|${_settings.value.speed}|${text.trim()}"

    /** Synthesizes [text] (or picks up where an earlier request for it got to). */
    private fun prepare(text: String): Deferred<FloatArray> = synchronized(prepared) {
        val key = key(text)
        prepared[key]?.let { return it }
        val settings = _settings.value
        val job = scope.async(synthesis) {
            // Kokoro's own speed keeps the voice natural; Media3 doesn't stretch it.
            tts.generate(text, settings.speaker, settings.speed.toFloat()).samples
        }
        prepared[key] = job
        // Keep the current sentence and the next two at most.
        while (prepared.size > 3) prepared.remove(prepared.keys.first())?.cancel()
        job
    }

    override fun speak(requestId: TtsEngine.RequestId, text: String, language: Language?) {
        current?.let { (id, job) ->
            job.cancel()
            player.stop()
            listener?.onFlushed(id)
        }
        val job = scope.launch {
            try {
                val audio = prepare(text).await()
                // While it plays, get the next sentence ready.
                launch { lookahead.after(text)?.let { prepare(it) } }
                main.post { listener?.onStart(requestId) }
                val finished = player.play(audio) { isActive }
                if (finished) {
                    main.post {
                        if (current?.first == requestId) current = null
                        listener?.onDone(requestId)
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                main.post { listener?.onError(requestId, KokoroError(e.message ?: "Kokoro couldn't read this")) }
            }
        }
        current = requestId to job
    }

    override fun stop() {
        val (id, job) = current ?: return
        current = null
        job.cancel()
        player.stop()
        listener?.onInterrupted(id)
    }

    override fun close() {
        stop()
        scope.cancel()
        synchronized(prepared) {
            prepared.values.forEach { it.cancel() }
            prepared.clear()
        }
        // After any synthesis still running on that thread.
        synthesisThread.execute { runCatching { tts.release() } }
        synthesisThread.shutdown()
        player.release()
    }

    /**
     * Walks the book as Readium does (the same content and sentence splitting), to know which
     * sentence comes after the one being spoken.
     */
    private inner class Lookahead {
        private var iterator: Content.Iterator? = null
        private val queue = ArrayDeque<String>()
        private var lastPredicted: String? = null
        private val lock = Mutex()

        private fun same(a: String, b: String) = a.trim() == b.trim()

        private suspend fun nextUtterance(): String? {
            while (queue.isEmpty()) {
                val element = iterator?.nextOrNull() ?: return null
                val tokenizer = TextContentTokenizer(
                    language = _settings.value.language,
                    overrideContentLanguage = false,
                    textTokenizerFactory = tokenizerFactory,
                )
                for (token in tokenizer.tokenize(element)) {
                    when (token) {
                        is Content.TextElement -> token.segments.forEach { if (it.text.any(Char::isLetterOrDigit)) queue.add(it.text) }
                        is Content.TextualElement -> token.text?.takeIf { t -> t.any(Char::isLetterOrDigit) }?.let(queue::add)
                        else -> {}
                    }
                }
            }
            return queue.removeFirst()
        }

        suspend fun after(text: String): String? = withContext(kotlinx.coroutines.Dispatchers.Default) {
            lock.withLock { predict(text) }
        }

        private suspend fun predict(text: String): String? {
            try {
                val predicted = lastPredicted
                if (predicted == null || !same(predicted, text)) {
                    // First sentence, or the reader jumped: start again from where it is,
                    // and find the sentence being spoken.
                    delay(150)
                    queue.clear()
                    iterator = publication.content(currentLocator())?.iterator()
                    var found = false
                    for (i in 0 until 40) {
                        val next = nextUtterance() ?: break
                        if (same(next, text)) {
                            found = true
                            break
                        }
                    }
                    if (!found) {
                        lastPredicted = null
                        return null
                    }
                }
                return nextUtterance().also { lastPredicted = it }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                lastPredicted = null
                return null
            }
        }
    }
}

@OptIn(ExperimentalReadiumApi::class)
class KokoroEngineProvider(
    private val context: Context,
    private val language: String?,
    private val currentLocator: () -> Locator?,
) : TtsEngineProvider<KokoroSettings, KokoroPreferences, KokoroPreferencesEditor, KokoroError, KokoroVoice> {

    val tokenizerFactory: (Language?) -> Tokenizer<String, IntRange> = { lang ->
        DefaultTextContentTokenizer(TextUnit.Sentence, lang)
    }

    override suspend fun createEngine(
        publication: Publication,
        initialPreferences: KokoroPreferences,
    ): Try<TtsEngine<KokoroSettings, KokoroPreferences, KokoroError, KokoroVoice>, org.readium.r2.shared.util.Error> =
        try {
            val tts = withContext(kotlinx.coroutines.Dispatchers.IO) { Kokoro.load(context, language) }
            val bookLanguage = Language(language ?: publication.metadata.languages.firstOrNull() ?: "en")
            Try.success(KokoroEngine(tts, publication, tokenizerFactory, currentLocator, initialPreferences, bookLanguage))
        } catch (e: Throwable) {
            Try.failure(KokoroError("Kokoro couldn't start: ${e.message}"))
        }

    override fun createPreferencesEditor(publication: Publication, initialPreferences: KokoroPreferences) =
        KokoroPreferencesEditor(initialPreferences)

    override fun createEmptyPreferences() = KokoroPreferences()

    override fun getPlaybackParameters(settings: KokoroSettings) = PlaybackParameters(settings.speed.toFloat())

    override fun updatePlaybackParameters(previousPreferences: KokoroPreferences, playbackParameters: PlaybackParameters) =
        previousPreferences.copy(speed = playbackParameters.speed.toDouble())

    override fun mapEngineError(error: KokoroError) =
        PlaybackException(error.message, null, PlaybackException.ERROR_CODE_UNSPECIFIED)
}
