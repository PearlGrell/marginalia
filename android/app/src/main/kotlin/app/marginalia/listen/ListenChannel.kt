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
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.Language
import org.readium.r2.shared.util.getOrElse

/**
 * Reading a book aloud with Kokoro's voices (`marginalia/listen`):
 * - `start {publicationId, locator?, speed, speaker?, language?}` → true; errors
 *   `not_installed` (the voices aren't downloaded), `unsupported_language`, `unsupported`
 * - `play`, `pause`, `nextSentence`, `previousSentence`, `nextChapter`, `previousChapter`,
 *   `goTo {locator}` (reads on from a tapped line: from the sentence in the locator's text)
 *
 * A locator given to `start` or `goTo` with a sentence as its text starts at that sentence,
 * not at the beginning of its paragraph.
 * - `setSpeed {speed}` (0.5 to 3), `voices` → `[{id, name, language, selected}]`,
 *   `setVoice {id}`
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

    private var navigator: TtsNavigator<KokoroSettings, KokoroPreferences, KokoroError, KokoroVoice>? = null
    private var publication: Publication? = null
    private var preferences = KokoroPreferences()
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
                preferences = preferences.copy(speed = call.argument<Double>("speed") ?: 1.0)
                navigator.submitPreferences(preferences)
            }
            "voices" -> {
                // Only voices that speak this book's language.
                val bookLanguages = bookLanguages().map { it.removeRegion().code }.toSet()
                val chosen = navigator.settings.value.speaker
                return result.success(
                    navigator.voices
                        .filter { bookLanguages.isEmpty() || it.language.removeRegion().code in bookLanguages }
                        .sortedBy { it.speaker }
                        .map {
                            mapOf(
                                "id" to it.speaker.toString(),
                                "name" to it.name,
                                "language" to it.language.code,
                                "selected" to (it.speaker == chosen),
                            )
                        },
                )
            }
            "setVoice" -> {
                val speaker = call.argument<String>("id")?.toIntOrNull()
                if (speaker != null) {
                    preferences = preferences.copy(speaker = speaker)
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
        val language = call.argument<String>("language") ?: publication.metadata.languages.firstOrNull()
        if (!Kokoro.isInstalled(activity)) {
            return result.error("not_installed", "Download the voices in Settings → Downloads.", null)
        }
        if (!Kokoro.supports(language)) {
            return result.error("unsupported_language", "There are no voices for this book's language yet.", null)
        }
        stop()
        askForNotifications()
        preferences = KokoroPreferences(
            speed = call.argument<Double>("speed") ?: 1.0,
            speaker = call.argument<Int>("speaker") ?: Kokoro.defaultSpeaker(language),
        )

        scope.launch {
            val provider = KokoroEngineProvider(activity.applicationContext, language) {
                this@ListenChannel.navigator?.location?.value?.utteranceLocator
            }
            val navigator = TtsNavigatorFactory(activity.application, publication, provider, provider.tokenizerFactory)
                ?.createNavigator(
                    listener = object : TtsNavigator.Listener {
                        override fun onStopRequested() = stop()
                    },
                    initialLocator = locator,
                    initialPreferences = preferences,
                )
                ?.getOrElse { null }
                ?: return@launch result.error("unsupported", "This book can't be read aloud.", null)
            this@ListenChannel.navigator = navigator
            this@ListenChannel.publication = publication
            observe(navigator)

            // Connecting a controller starts the media session service.
            Listening.player = navigator.asMedia3Player()
            val token = SessionToken(activity, ComponentName(activity, ListenService::class.java))
            controller = MediaController.Builder(activity, token).buildAsync()

            result.success(true)
            if (locator?.text?.highlight.isNullOrBlank()) navigator.play() else seek(navigator, null, locator?.text?.highlight)
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
        navigator: TtsNavigator<KokoroSettings, KokoroPreferences, KokoroError, KokoroVoice>,
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

    private fun bookLanguages(): List<Language> =
        publication?.metadata?.languages.orEmpty().map { Language(it) }

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
