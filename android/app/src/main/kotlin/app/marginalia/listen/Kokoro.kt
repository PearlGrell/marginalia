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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
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
 * Downloads into [dir]; Listen needs it.
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
     * All synthesis runs on this one thread. The native model is not thread-safe, and one
     * thread also means it is never released while in use.
     */
    val thread: java.util.concurrent.ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "kokoro").apply { priority = Thread.NORM_PRIORITY + 1 }
    }
    val dispatcher = thread.asCoroutineDispatcher()

    /** The one model in memory (it takes a few hundred MB), set up for [loadedFor]. */
    private var model: OfflineTts? = null
    private var loadedFor: String? = null

    /** espeak-ng's voice for a book language; "" lets the lexicons handle English and Chinese. */
    private fun espeakFor(language: String?): String {
        val lang = language?.lowercase().orEmpty()
        return when {
            lang.startsWith("es") -> "es"
            lang.startsWith("fr") -> "fr"
            lang.startsWith("hi") -> "hi"
            lang.startsWith("it") -> "it"
            lang.startsWith("ja") -> "ja"
            lang.startsWith("pt") -> "pt-BR"
            else -> ""
        }
    }

    private fun keyFor(language: String?): String {
        val lang = language?.lowercase().orEmpty()
        val british = lang.startsWith("en-gb") || lang.startsWith("en_gb")
        return espeakFor(language) + if (british) "|gb" else ""
    }

    /**
     * The model set up for reading [language], loading it (a second or two) only when the
     * language changes. Call on [thread] only.
     */
    fun modelFor(context: Context, language: String?): OfflineTts {
        val key = keyFor(language)
        model?.let { if (loadedFor == key) return it }
        model?.release()
        model = null
        loadedFor = null
        return load(context, language).also {
            model = it
            loadedFor = key
        }
    }

    /** Frees the model's memory (after the voices are removed). Call on [thread] only. */
    fun unload() {
        model?.release()
        model = null
        loadedFor = null
    }

    private fun load(context: Context, language: String?): OfflineTts {
        val d = dir(context).absolutePath
        val lang = language?.lowercase().orEmpty()
        val british = lang.startsWith("en-gb") || lang.startsWith("en_gb")
        // One English lexicon (with both, words would be listed twice) plus Chinese.
        val lexicons = listOf(if (british) "lexicon-gb-en.txt" else "lexicon-us-en.txt", "lexicon-zh.txt")
        val config = OfflineTtsConfig(
            model = OfflineTtsModelConfig(
                kokoro = OfflineTtsKokoroModelConfig(
                    model = "$d/model.int8.onnx",
                    voices = "$d/voices.bin",
                    tokens = "$d/tokens.txt",
                    dataDir = "$d/espeak-ng-data",
                    lexicon = lexicons.filter { File(d, it).isFile }.joinToString(",") { "$d/$it" },
                    lang = espeakFor(language),
                    dictDir = "$d/dict",
                    lengthScale = 1.0f,
                ),
                numThreads = performanceCores().coerceIn(2, 4),
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

    /**
     * The phone's fast cores: synthesis spread over slow efficiency cores as well runs slower
     * than on the fast ones alone. All cores, if their speeds can't be read.
     */
    private fun performanceCores(): Int {
        val all = Runtime.getRuntime().availableProcessors()
        val speeds = (0 until all).mapNotNull {
            runCatching {
                File("/sys/devices/system/cpu/cpu$it/cpufreq/cpuinfo_max_freq").readText().trim().toLong()
            }.getOrNull()
        }
        if (speeds.size != all) return all
        val fastest = speeds.max()
        return speeds.count { it >= fastest * 0.7 }
    }
}

/**
 * Pieces of a sentence to synthesize one after another, so the first is heard sooner and
 * the rest are made while it plays. Short sentences stay whole (splitting them changes how
 * they sound); long ones break after commas and the like, into pieces of [min] characters
 * or more.
 */
internal fun clauses(text: String, min: Int = 50, whole: Int = 140): List<String> {
    val t = text.trim()
    if (t.length <= whole) return listOf(t)
    val parts = mutableListOf<String>()
    val piece = StringBuilder()
    for (part in t.split(Regex("(?<=[,;:\u2014\u2013\u3001\uFF0C\uFF1B\uFF1A])\\s*"))) {
        if (part.isEmpty()) continue
        if (piece.isNotEmpty()) piece.append(' ')
        piece.append(part)
        if (piece.length >= min) {
            parts += piece.toString()
            piece.clear()
        }
    }
    if (piece.isNotEmpty()) {
        // A short end goes with the piece before it.
        if (parts.isNotEmpty() && piece.length < min / 2) parts[parts.lastIndex] = parts.last() + " " + piece else parts += piece.toString()
    }
    return parts
}

/**
 * [samples] without the near-silence Kokoro puts around speech, keeping [lead] and [tail]
 * seconds of it: the pause between sentences is then the voice's, not padding.
 */
internal fun trimSilence(samples: FloatArray, sampleRate: Int, lead: Double, tail: Double, threshold: Float = 0.006f): FloatArray {
    var start = 0
    while (start < samples.size && kotlin.math.abs(samples[start]) < threshold) start++
    if (start == samples.size) return FloatArray((tail * sampleRate).toInt())
    var end = samples.size - 1
    while (end > start && kotlin.math.abs(samples[end]) < threshold) end--
    val from = (start - (lead * sampleRate).toInt()).coerceAtLeast(0)
    val to = (end + 1 + (tail * sampleRate).toInt()).coerceAtMost(samples.size)
    return if (from == 0 && to == samples.size) samples else samples.copyOfRange(from, to)
}

/**
 * One sentence's audio, made a piece at a time: it can be played while the rest is still
 * being made, and abandoned part way.
 */
internal class Synthesis {
    private val chunks = ArrayList<FloatArray>()
    private val changes = MutableStateFlow(0)

    @Volatile private var done = false

    @Volatile private var error: Throwable? = null

    /** Set to stop making it (checked between pieces). */
    @Volatile var cancelled = false

    fun add(samples: FloatArray) {
        synchronized(chunks) { chunks.add(samples) }
        changes.update { it + 1 }
    }

    fun finish(error: Throwable? = null) {
        this.error = error
        done = true
        changes.update { it + 1 }
    }

    /** Piece [i], once it's made; null after the last. */
    suspend fun chunk(i: Int): FloatArray? {
        while (true) {
            val seen = changes.value
            synchronized(chunks) { if (i < chunks.size) return chunks[i] }
            if (done) {
                error?.let { throw it }
                synchronized(chunks) { return chunks.getOrNull(i) }
            }
            changes.first { it != seen }
        }
    }
}

/** Plays mono float PCM, as it arrives, until it has been heard. */
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
    suspend fun play(samples: FloatArray, isActive: () -> Boolean): Boolean =
        play({ if (it == 0) samples else null }, isActive)

    /** Plays the pieces [next] gives (null after the last). Returns false if stopped before the end. */
    suspend fun play(next: suspend (Int) -> FloatArray?, isActive: () -> Boolean): Boolean {
        stopped = false
        track.play()
        val start = track.playbackHeadPosition
        var written = 0
        var index = 0
        while (true) {
            if (stopped || !isActive()) return false
            val samples = next(index++) ?: break
            var offset = 0
            while (offset < samples.size) {
                if (stopped || !isActive()) return false
                val n = track.write(samples, offset, minOf(CHUNK, samples.size - offset), AudioTrack.WRITE_BLOCKING)
                if (n <= 0) break
                offset += n
            }
            written += samples.size
        }
        // Wait until the last of it has come out of the speaker.
        while (!stopped && isActive() && track.playbackHeadPosition - start < written) {
            delay(10)
        }
        return !stopped
    }

    private companion object {
        const val CHUNK = 4096
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
 * Readium's text-to-speech engine, speaking with Kokoro. Sentences are made ahead of time
 * ([Lookahead] knows which come next), and each one a piece at a time, so reading flows
 * without pauses and starts quickly. Work for sentences that won't be read (after a jump) is
 * dropped at once, so it never holds up the one that will.
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

    /** sherpa-onnx isn't thread-safe: every synthesis goes through Kokoro's one thread. */
    private val kokoroThread = Kokoro.dispatcher
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
    private val prepared = LinkedHashMap<String, Prepared>()

    private class Prepared(val synthesis: Synthesis, val job: Job) {
        fun cancel() {
            synthesis.cancelled = true
            job.cancel()
        }
    }

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
    private fun prepare(text: String): Synthesis = synchronized(prepared) {
        val key = key(text)
        prepared[key]?.let { return it.synthesis }
        val settings = _settings.value
        val sampleRate = tts.sampleRate()
        val synthesis = Synthesis()
        val job = scope.launch(kokoroThread) {
            try {
                val started = System.nanoTime()
                val pieces = clauses(text)
                var first = true
                var heard = 0
                for (piece in pieces) {
                    if (synthesis.cancelled) break
                    // Kokoro's own speed keeps the voice natural; Media3 doesn't stretch it.
                    tts.generateWithCallback(piece, settings.speaker, settings.speed.toFloat()) { samples ->
                        if (synthesis.cancelled) return@generateWithCallback 0
                        val trimmed = trimSilence(samples, sampleRate, lead = if (first) LEAD else 0.0, tail = TAIL)
                        first = false
                        heard += trimmed.size
                        synthesis.add(trimmed)
                        1
                    }
                }
                synthesis.finish()
                if (!synthesis.cancelled) {
                    val ms = (System.nanoTime() - started) / 1_000_000
                    android.util.Log.d("Kokoro", "${text.length} chars in ${pieces.size}: ${ms} ms for ${heard * 1000L / sampleRate} ms of speech")
                }
            } catch (e: Throwable) {
                synthesis.finish(e.takeUnless { it is kotlinx.coroutines.CancellationException })
                if (e is kotlinx.coroutines.CancellationException) throw e
            }
        }
        prepared[key] = Prepared(synthesis, job)
        while (prepared.size > MAX_PREPARED) prepared.remove(prepared.keys.first())?.cancel()
        synthesis
    }

    override fun speak(requestId: TtsEngine.RequestId, text: String, language: Language?) {
        current?.let { (id, job) ->
            job.cancel()
            player.stop()
            listener?.onFlushed(id)
        }
        val key = key(text)
        val synthesis = synchronized(prepared) {
            // Not what was expected next (a jump): what was made ahead won't be read.
            if (key !in prepared) {
                prepared.values.forEach { it.cancel() }
                prepared.clear()
            }
            prepare(text)
        }
        val job = scope.launch {
            try {
                // The sentences after it, queued behind it right away.
                launch { lookahead.after(text, AHEAD).forEach { prepare(it) } }
                val first = synthesis.chunk(0)
                main.post { listener?.onStart(requestId) }
                val finished = player.play({ if (it == 0) first else synthesis.chunk(it) }) { isActive }
                if (finished) {
                    synchronized(prepared) { prepared.remove(key) }
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

    private companion object {
        /** Sentences made ahead of the one being read. */
        const val AHEAD = 3
        const val MAX_PREPARED = AHEAD + 3

        /** Silence kept before a sentence and after each piece, in seconds. */
        const val LEAD = 0.02
        const val TAIL = 0.11
        val SPACES = Regex("\\s+")
    }

    override fun close() {
        stop()
        scope.cancel()
        synchronized(prepared) {
            prepared.values.forEach { it.cancel() }
            prepared.clear()
        }
        // The model stays loaded (it's shared, and slow to load); only playback goes.
        player.release()
    }

    /**
     * Walks the book as Readium does (the same content and sentence splitting), to know which
     * sentence comes after the one being spoken.
     */
    private inner class Lookahead {
        private var iterator: Content.Iterator? = null

        /** Sentences read from the book but not yet handed out. */
        private val queue = ArrayDeque<String>()

        /** The sentence being spoken, and the ones known to follow it. */
        private var spoken: String? = null
        private val upcoming = ArrayDeque<String>()
        private val lock = Mutex()

        private fun same(a: String, b: String) = a.replace(SPACES, " ").trim() == b.replace(SPACES, " ").trim()

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

        /** Up to [count] sentences that follow [text], the one starting to be spoken. */
        suspend fun after(text: String, count: Int): List<String> = withContext(kotlinx.coroutines.Dispatchers.Default) {
            lock.withLock { predict(text, count) }
        }

        private suspend fun predict(text: String, count: Int): List<String> {
            try {
                when {
                    upcoming.isNotEmpty() && same(upcoming.first(), text) -> upcoming.removeFirst()
                    spoken != null && same(spoken!!, text) -> {}
                    // First sentence, or the reader jumped: start again from where it is.
                    !resync(text) -> {
                        spoken = null
                        upcoming.clear()
                        return emptyList()
                    }
                }
                spoken = text
                while (upcoming.size < count) upcoming.add(nextUtterance() ?: break)
                return upcoming.toList()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                spoken = null
                upcoming.clear()
                return emptyList()
            }
        }

        /** Walks from the reader's position to [text]; false if it isn't there. */
        private suspend fun resync(text: String): Boolean {
            upcoming.clear()
            // Readium may report the new position just after asking for the sentence.
            for (attempt in 0 until 2) {
                if (attempt > 0) delay(150)
                queue.clear()
                iterator = publication.content(currentLocator())?.iterator() ?: return false
                for (i in 0 until 60) {
                    val next = nextUtterance() ?: break
                    if (same(next, text)) return true
                }
            }
            return false
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
            val tts = withContext(Kokoro.dispatcher) { Kokoro.modelFor(context, language) }
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
