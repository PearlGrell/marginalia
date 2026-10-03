package app.marginalia.listen

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream

/**
 * Kokoro's voices outside any book (`marginalia/voices`):
 * - `kokoroInstalled` → bool
 * - `installKokoro {path}` unpacks the downloaded model (reporting `onKokoroProgress
 *   {fraction}`) → bool; `removeKokoro`
 * - `kokoroSample {speaker, text, language}` speaks a sample, returning when it ends; `stop`
 */
class VoicesChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "marginalia/voices").also {
        it.setMethodCallHandler(this)
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var kokoroPlayer: PcmPlayer? = null
    private var sample: Job? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stop" -> {
                stopSample()
                result.success(null)
            }
            "kokoroInstalled" -> result.success(Kokoro.isInstalled(activity))
            "installKokoro" -> {
                val path = call.argument<String>("path") ?: return result.error("bad_args", "path", null)
                scope.launch {
                    val ok = try {
                        withContext(Dispatchers.IO) { unpack(File(path)) }
                        true
                    } catch (_: Throwable) {
                        false
                    }
                    result.success(ok && Kokoro.isInstalled(activity))
                }
            }
            "removeKokoro" -> {
                stopSample()
                scope.launch {
                    withContext(Kokoro.dispatcher) { Kokoro.unload() }
                    withContext(Dispatchers.IO) { File(activity.filesDir, "kokoro").deleteRecursively() }
                    result.success(null)
                }
            }
            "kokoroSample" -> {
                val speaker = call.argument<Int>("speaker") ?: 0
                val text = call.argument<String>("text") ?: ""
                val language = call.argument<String>("language") ?: Kokoro.languageOf(speaker)
                if (!Kokoro.isInstalled(activity)) return result.error("not_installed", "Kokoro isn't downloaded", null)
                stopSample()
                sample = scope.launch {
                    try {
                        // One at a time, on Kokoro's own thread: tapping another voice while one
                        // is being made waits for it instead of running two at once.
                        val audio = withContext(Kokoro.dispatcher) {
                            Kokoro.modelFor(activity, language).generate(text, speaker, 1.0f)
                        }
                        if (!isActive) return@launch result.success(false)
                        val player = kokoroPlayer ?: PcmPlayer(audio.sampleRate).also { kokoroPlayer = it }
                        withContext(Dispatchers.Default) { player.play(audio.samples) { isActive } }
                        result.success(true)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        result.success(false)
                        throw e
                    } catch (e: Throwable) {
                        // Never let a sample take the app down (a model that won't load, low memory).
                        result.error("sample_failed", e.message ?: e.javaClass.simpleName, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun stopSample() {
        sample?.cancel()
        sample = null
        kokoroPlayer?.stop()
    }

    /** Unpacks the model's .tar.bz2 next to where it's used, replacing any earlier copy. */
    private fun unpack(archive: File) {
        val root = File(activity.filesDir, "kokoro")
        val staging = File(activity.filesDir, "kokoro.part").apply { deleteRecursively(); mkdirs() }
        val total = archive.length().coerceAtLeast(1)
        var lastReported = -1
        val counting = object : java.io.FilterInputStream(archive.inputStream().buffered(1 shl 16)) {
            var read = 0L

            override fun read(): Int = super.read().also { if (it >= 0) progress(1) }

            override fun read(b: ByteArray, off: Int, len: Int): Int =
                super.read(b, off, len).also { if (it > 0) progress(it) }

            private fun progress(n: Int) {
                read += n
                val percent = (read * 100 / total).toInt()
                if (percent != lastReported) {
                    lastReported = percent
                    activity.runOnUiThread {
                        channel.invokeMethod("onKokoroProgress", mapOf("fraction" to percent / 100.0))
                    }
                }
            }
        }
        TarArchiveInputStream(BZip2CompressorInputStream(counting)).use { tar ->
            val base = staging.canonicalPath
            while (true) {
                val entry = tar.nextEntry ?: break
                val out = File(staging, entry.name)
                // Never write outside the folder, whatever the archive says.
                if (!out.canonicalPath.startsWith(base + File.separator)) continue
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    out.outputStream().use { tar.copyTo(it, 1 shl 16) }
                }
            }
        }
        root.deleteRecursively()
        if (!staging.renameTo(root)) {
            staging.copyRecursively(root, overwrite = true)
            staging.deleteRecursively()
        }
        archive.delete()
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        stopSample()
        kokoroPlayer?.release()
        kokoroPlayer = null
        scope.cancel()
    }
}
