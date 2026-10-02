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
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
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
 * - `play`, `pause`, `nextSentence`, `previousSentence`, `nextChapter`, `previousChapter`
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

            navigator.play()
            result.success(true)
        }
    }

    private fun observe(navigator: TtsNavigator<*, *, *, *>) {
        observers?.cancel()
        observers = scope.launch {
            navigator.location
                .onEach {
                    channel.invokeMethod(
                        "onUtterance",
                        mapOf("locator" to it.utteranceLocator.toJSON().toString(), "text" to it.utterance),
                    )
                }
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
}
