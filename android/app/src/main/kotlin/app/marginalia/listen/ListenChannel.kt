package app.marginalia.listen

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.marginalia.readium.PublicationRepository
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.readium.navigator.media.common.MediaNavigator
import org.readium.navigator.media.tts.TtsNavigator
import org.readium.navigator.media.tts.TtsNavigatorFactory
import org.readium.navigator.media.tts.android.AndroidTtsEngine
import org.readium.navigator.media.tts.android.AndroidTtsEngineProvider
import org.readium.navigator.media.tts.android.AndroidTtsPreferences
import org.readium.navigator.media.tts.android.AndroidTtsSettings
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.Language
import org.readium.r2.shared.util.getOrElse

/**
 * Reading a book aloud with the phone's own text-to-speech, as Leigha or Alex (see
 * [Narrators]) (`marginalia/listen`):
 * - `start {publicationId, locator?, speed, narrator?, language?}` → true; errors
 *   `no_voice` (the phone has no voice for the book's language), `no_engine` (its
 *   text-to-speech didn't start), `unsupported` (no text to read, even from the chapter's or
 *   the book's start)
 * - `play`, `pause`, `nextSentence`, `previousSentence`, `nextChapter`, `previousChapter`,
 *   `goTo {locator}` (reads on from a tapped line: from the sentence in the locator's text)
 *
 * A locator given to `start` or `goTo` with a sentence as its text starts at that sentence,
 * not at the beginning of its paragraph.
 * - `setSpeed {speed}` (0.5 to 3), `voices` → `[{id, name, selected}]` (the narrators this
 *   book can have), `setVoice {id}` ("leigha" or "alex")
 * - `stop`
 *
 * Calls Dart with `onUtterance {locator, text}` for each sentence (to highlight it and turn
 * pages) and `onPlayback {playing, ended}`.
 */
@OptIn(ExperimentalReadiumApi::class)
class ListenChannel(
    messenger: BinaryMessenger,
    private val activity: FragmentActivity,
    private val repository: PublicationRepository,
) : MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, "marginalia/listen").also {
        it.setMethodCallHandler(this)
    }

    private var navigator: TtsNavigator<AndroidTtsSettings, AndroidTtsPreferences, AndroidTtsEngine.Error, AndroidTtsEngine.Voice>? = null
    private var publication: Publication? = null
    private var preferences = AndroidTtsPreferences()

    /** The book's narrators, and who is reading. */
    private var narrators: Map<Narrator, AndroidTtsEngine.Voice> = emptyMap()
    private var narrator = Narrator.Leigha
    private var bookLanguage = "en"
    private var controller: ListenableFuture<MediaController>? = null
    private var observers: Job? = null

    /** Skipping silently to a sentence: sentences passed on the way aren't reported. */
    private var seeking: Job? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "start") return start(call, result)
        if (call.method == "stop") {
            stop()
            return result.success(null)
        }
        val navigator = navigator ?: return result.error("not_started", "Not listening", null)
        when (call.method) {
            "play" -> navigator.play()
            "pause" -> navigator.pause()
            "nextSentence" -> navigator.skipToNextUtterance()
            "previousSentence" -> navigator.skipToPreviousUtterance()
            "nextChapter" -> skipChapter(navigator, 1)
            "previousChapter" -> skipChapter(navigator, -1)
            "goTo" -> {
                // A line tapped in the page: read on from there.
                val locator = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
                    ?: return result.error("bad_args", "locator is invalid", null)
                seek(navigator, locator)
            }
            "setSpeed" -> {
                preferences = AndroidTtsPreferences(
                    language = preferences.language,
                    pitch = preferences.pitch,
                    speed = call.argument<Double>("speed") ?: 1.0,
                    voices = preferences.voices,
                )
                navigator.submitPreferences(preferences)
            }
            "voices" -> return result.success(
                Narrator.entries.filter { it in narrators }.map {
                    mapOf("id" to it.id, "name" to it.label, "selected" to (it == narrator))
                },
            )
            "setVoice" -> {
                val chosen = Narrator.byId(call.argument<String>("id"))
                if (chosen != null && chosen in narrators) {
                    narrator = chosen
                    preferences = preferences.withNarrator()
                    navigator.submitPreferences(preferences)
                }
            }
            else -> return result.notImplemented()
        }
        result.success(null)
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val publication = call.argument<String>("publicationId")?.let(repository::get)
            ?: return result.error("bad_args", "The book is not open", null)
        val locator = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
        val language = call.argument<String>("language") ?: publication.metadata.languages.firstOrNull() ?: "en"
        stop()
        askForNotifications()
        bookLanguage = language
        narrator = Narrator.byId(call.argument<String>("narrator")) ?: Narrator.Leigha
        preferences = AndroidTtsPreferences(speed = call.argument<Double>("speed") ?: 1.0)

        scope.launch {
            val factory = TtsNavigatorFactory(activity.application, publication, AndroidTtsEngineProvider(activity.application))
                ?: return@launch result.error("unsupported", "This book has no text to read aloud.", null)
            // From the page; failing that, the top of its chapter; failing that, the start of
            // the book (a page with nothing readable from there on, or a place Readium can't
            // start at).
            val chapterStart = locator?.let { publication.linkWithHref(it.href)?.let(publication::locatorFromLink) }
            var engineFailed = false
            var navigator: TtsNavigator<AndroidTtsSettings, AndroidTtsPreferences, AndroidTtsEngine.Error, AndroidTtsEngine.Voice>? = null
            var startedFrom: Locator? = null
            for (from in listOf(locator, chapterStart, null).distinct()) {
                startedFrom = from
                val created = try {
                    withTimeoutOrNull(START_TIMEOUT_MS) {
                        factory.createNavigator(
                            listener = object : TtsNavigator.Listener {
                                override fun onStopRequested() = stop()
                            },
                            initialLocator = from,
                            initialPreferences = preferences,
                        )
                    }
                } catch (e: Exception) {
                    android.util.Log.w("Listen", "Couldn't start from $from", e)
                    continue
                }
                if (created == null) {
                    // The phone's speech engine never answered.
                    android.util.Log.w("Listen", "The text-to-speech engine didn't start in time")
                    engineFailed = true
                    break
                }
                navigator = created.getOrElse { error ->
                    android.util.Log.w("Listen", "Couldn't start from $from: ${error.message} (${error.cause?.message})")
                    if (error is TtsNavigatorFactory.Error.EngineInitialization) engineFailed = true
                    null
                }
                if (navigator != null || engineFailed) break
            }
            if (navigator == null) {
                return@launch if (engineFailed) {
                    result.error(
                        "no_engine",
                        "Your phone's text-to-speech didn't start. Check Settings › System › Languages › Text-to-speech output, then try again.",
                        null,
                    )
                } else {
                    result.error("unsupported", "This book has no text to read aloud from here.", null)
                }
            }
            if (startedFrom != locator) android.util.Log.i("Listen", "Started from $startedFrom: the page itself couldn't be")
            narrators = narratorsFor(navigator.voices, language)
            if (narrators.isEmpty()) {
                navigator.close()
                return@launch result.error(
                    "no_voice",
                    "Your phone has no voice for this book's language. Add one in Android's text-to-speech settings.",
                    null,
                )
            }
            if (narrator !in narrators) narrator = narrators.keys.first()
            preferences = preferences.withNarrator()
            navigator.submitPreferences(preferences)
            this@ListenChannel.navigator = navigator
            this@ListenChannel.publication = publication
            observe(navigator)

            // Connecting a controller starts the media session service.
            Listening.player = navigator.asMedia3Player()
            val token = SessionToken(activity, ComponentName(activity, ListenService::class.java))
            controller = MediaController.Builder(activity, token).buildAsync()

            result.success(true)
            // Started on the page: from its first sentence (Readium starts at its paragraph).
            val sentence = locator?.text?.highlight.takeIf { startedFrom == locator }
            if (sentence.isNullOrBlank()) navigator.play() else seek(navigator, null, sentence)
        }
    }

    private fun observe(navigator: TtsNavigator<*, *, *, *>) {
        observers?.cancel()
        observers = scope.launch {
            navigator.location
                .onEach { if (seeking?.isActive != true) report(it) }
                .launchIn(this)
            navigator.playback
                .onEach {
                    channel.invokeMethod(
                        "onPlayback",
                        mapOf(
                            "playing" to (it.playWhenReady && it.state is MediaNavigator.State.Ready),
                            "ended" to (it.state is MediaNavigator.State.Ended),
                        ),
                    )
                }
                .launchIn(this)
        }
    }

    private fun report(location: TtsNavigator.Location) {
        channel.invokeMethod(
            "onUtterance",
            mapOf("locator" to location.utteranceLocator.toJSON().toString(), "text" to location.utterance),
        )
    }

    /**
     * Reads on from [sentence] (by default, [locator]'s text): goes to [locator]'s paragraph,
     * then skips, silently and without speaking, to the first sentence that matches. Readium
     * only goes to the start of a paragraph, so a tap on its third line would otherwise read
     * it again from the top.
     */
    private fun seek(
        navigator: TtsNavigator<AndroidTtsSettings, AndroidTtsPreferences, AndroidTtsEngine.Error, AndroidTtsEngine.Voice>,
        locator: Locator?,
        sentence: String? = locator?.text?.highlight,
    ) {
        seeking?.cancel()
        seeking = scope.launch {
            navigator.pause()
            if (locator != null) {
                val before = navigator.location.value
                navigator.go(locator)
                withTimeoutOrNull(SETTLE_MS) { navigator.location.first { it != before } }
            }
            val target = sentence?.let(::matchKey).orEmpty()
            if (target.length >= MIN_MATCH) {
                var location = navigator.location.value
                var steps = 0
                while (!sameSentence(matchKey(location.utterance), target) && steps < MAX_SKIP && navigator.hasNextUtterance()) {
                    val passed = location
                    navigator.skipToNextUtterance()
                    location = withTimeoutOrNull(SETTLE_MS) { navigator.location.first { it != passed } } ?: break
                    steps++
                }
                // Not found nearby: read the paragraph from its start rather than somewhere else.
                if (!sameSentence(matchKey(location.utterance), target) && locator != null) {
                    navigator.go(locator)
                    withTimeoutOrNull(SETTLE_MS) { navigator.location.first { it != location } }
                }
            }
            report(navigator.location.value)
            navigator.play()
        }
    }

    /** Leigha's and Alex's voices for [language], from the phone's. */
    private fun narratorsFor(voices: Set<AndroidTtsEngine.Voice>, language: String): Map<Narrator, AndroidTtsEngine.Voice> {
        val byName = voices.associateBy { it.id.value }
        val infos = voices.map { VoiceInfo(it.id.value, it.language.code, it.quality.ordinal, it.requiresNetwork) }
        val region = activity.resources.configuration.locales[0].country
        val picked = Narrators.pick(infos, language, region)
        android.util.Log.i("Listen", "Narrators for $language: ${picked.mapValues { it.value.name }}")
        return picked.mapNotNull { (n, info) -> byName[info.name]?.let { n to it } }.toMap()
    }

    /** These preferences, read by the chosen narrator (for the book's language with or without its region). */
    private fun AndroidTtsPreferences.withNarrator(): AndroidTtsPreferences {
        val voice = narrators[narrator] ?: return this
        val book = Language(bookLanguage)
        val keys = setOf(book, book.removeRegion(), voice.language, voice.language.removeRegion())
        return AndroidTtsPreferences(language = language, pitch = pitch, speed = speed, voices = keys.associateWith { voice.id })
    }

    private fun skipChapter(navigator: TtsNavigator<*, *, *, *>, step: Int) {
        val items = navigator.readingOrder.items
        val current = items.indexOfFirst { it.href == navigator.location.value.href }
        val target = items.getOrNull(current + step) ?: return
        val link = publication?.readingOrder?.firstOrNull { it.url() == target.href } ?: return
        navigator.go(link, animated = false)
        navigator.play()
    }

    /** The playback notification needs this on Android 13 and later; reading works without. */
    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val permission = Manifest.permission.POST_NOTIFICATIONS
        if (ContextCompat.checkSelfPermission(activity, permission) == PackageManager.PERMISSION_GRANTED) {
            return
        }
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<String>
        launcher = activity.activityResultRegistry.register(
            "marginalia-notifications",
            ActivityResultContracts.RequestPermission(),
        ) { launcher.unregister() }
        launcher.launch(permission)
    }

    fun stop() {
        seeking?.cancel()
        seeking = null
        observers?.cancel()
        observers = null
        navigator?.close()
        navigator = null
        publication = null
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
        Listening.player = null
        activity.stopService(Intent(activity, ListenService::class.java))
        channel.invokeMethod("onPlayback", mapOf("playing" to false, "ended" to false, "stopped" to true))
    }

    fun dispose() {
        stop()
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    private companion object {
        const val SETTLE_MS = 1500L

        /** How long the phone's speech engine gets to start (it never answers, on some). */
        const val START_TIMEOUT_MS = 15_000L

        /** How far past a tapped paragraph's start to look for the sentence. */
        const val MAX_SKIP = 60
        const val MIN_MATCH = 8
    }
}

/** Text to compare sentences by: letters and digits, lowercase, single spaces. */
internal fun matchKey(text: String): String =
    text.lowercase().map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("").replace(Regex(" +"), " ").trim()

/**
 * Whether Readium's sentence [utterance] is the one the page found ([target]), both as
 * [matchKey]s. The page and Readium split sentences a little differently (abbreviations,
 * quotes), so a shared start is enough.
 */
internal fun sameSentence(utterance: String, target: String): Boolean {
    if (utterance.isEmpty() || target.isEmpty()) return false
    val probe = minOf(30, utterance.length, target.length)
    return utterance.startsWith(target.take(probe)) || target.startsWith(utterance.take(probe)) ||
        (target.length >= 20 && utterance.contains(target.take(20)))
}
