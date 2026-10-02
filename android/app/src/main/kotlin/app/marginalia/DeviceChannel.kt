package app.marginalia

import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.util.concurrent.atomic.AtomicInteger
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reader conveniences that need the activity:
 * - `deviceName` → for example "Pixel 8", shown to other devices ("Pixel 8 is on page 214")
 * - `shareText {text}` opens Android's share sheet
 * - `shareImage {path}` opens the share sheet with a story card
 * - `saveImage {path, name}` saves it to Pictures/Marginalia and opens it → saved?
 * - `saveDocument {path, name, mime}` lets the reader pick where to save a file → saved?
 * - `shareFile {path, mime}` opens the share sheet with any file from the app's cache
 * - `updateWidget {bookId?, title, author, progress, coverPath}` keeps the home-screen
 *   Continue reading widget current
 * - `setKeepScreenOn {on}`
 * - `setVolumeKeysTurnPages {on}`: volume down/up are consumed and reported to Dart as
 *   `onVolumeKey {forward}` instead of changing the volume.
 */
class DeviceChannel(
    messenger: BinaryMessenger,
    private val activity: ComponentActivity,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "marginalia/device").also {
        it.setMethodCallHandler(this)
    }
    private var volumeKeysTurnPages = false
    private val requestCount = AtomicInteger()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val on = call.argument<Boolean>("on") == true
        when (call.method) {
            "setKeepScreenOn" -> {
                if (on) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "deviceName" -> {
                val maker = android.os.Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
                val model = android.os.Build.MODEL
                result.success(if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model")
            }
            "shareText" -> {
                val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(android.content.Intent.EXTRA_TEXT, call.argument<String>("text"))
                activity.startActivity(android.content.Intent.createChooser(send, null))
                result.success(null)
            }
            "shareImage" -> {
                shareImage(call.argument<String>("path") ?: return result.error("bad_args", "path", null))
                result.success(null)
            }
            "saveDocument" -> saveDocument(
                path = call.argument<String>("path") ?: return result.error("bad_args", "path", null),
                name = call.argument<String>("name") ?: "Marginalia",
                mime = call.argument<String>("mime") ?: "application/octet-stream",
                result = result,
            )
            "shareFile" -> {
                val file = java.io.File(call.argument<String>("path") ?: return result.error("bad_args", "path", null))
                val uri = androidx.core.content.FileProvider.getUriForFile(activity, "app.marginalia.files", file)
                val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType(call.argument<String>("mime") ?: "application/octet-stream")
                    .putExtra(android.content.Intent.EXTRA_STREAM, uri)
                    .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                activity.startActivity(android.content.Intent.createChooser(send, null))
                result.success(null)
            }
            "saveImage" -> {
                result.success(
                    saveImage(
                        path = call.argument<String>("path") ?: return result.error("bad_args", "path", null),
                        name = call.argument<String>("name") ?: "marginalia-${System.currentTimeMillis()}.png",
                    ),
                )
            }
            "updateWidget" -> {
                ContinueReadingWidget.update(
                    activity,
                    bookId = call.argument<String>("bookId"),
                    title = call.argument<String>("title"),
                    author = call.argument<String>("author"),
                    progress = call.argument<Double>("progress") ?: 0.0,
                    coverPath = call.argument<String>("coverPath"),
                )
                result.success(null)
            }
            "setVolumeKeysTurnPages" -> {
                volumeKeysTurnPages = on
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The system "save as" screen; the file is copied where the reader chooses. */
    private fun saveDocument(path: String, name: String, mime: String, result: MethodChannel.Result) {
        val key = "marginalia-save-${requestCount.incrementAndGet()}"
        lateinit var launcher: androidx.activity.result.ActivityResultLauncher<String>
        launcher = activity.activityResultRegistry.register(
            key,
            ActivityResultContracts.CreateDocument(mime),
        ) { target ->
            launcher.unregister()
            if (target == null) return@register result.success(false)
            // Large exports (a whole library) copy off the main thread.
            Thread {
                val ok = try {
                    activity.contentResolver.openOutputStream(target)!!.use { out ->
                        java.io.File(path).inputStream().use { it.copyTo(out, 1 shl 16) }
                    }
                    true
                } catch (_: Exception) {
                    false
                }
                activity.runOnUiThread { result.success(ok) }
            }.start()
        }
        launcher.launch(name)
    }

    /** Opens the Android share sheet with a PNG. */
    private fun shareImage(path: String) {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            activity,
            "app.marginalia.files",
            java.io.File(path),
        )
        val send = android.content.Intent(android.content.Intent.ACTION_SEND)
            .setType("image/png")
            .putExtra(android.content.Intent.EXTRA_STREAM, uri)
            .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.startActivity(android.content.Intent.createChooser(send, null))
    }

    /**
     * Copies a PNG into Pictures/Marginalia, where the gallery finds it, then opens it in
     * the photo viewer. Returns false if it couldn't be saved.
     */
    private fun saveImage(path: String, name: String): Boolean {
        val source = java.io.File(path)
        val uri: android.net.Uri = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val resolver = activity.contentResolver
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, name)
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(
                    android.provider.MediaStore.Images.Media.RELATIVE_PATH,
                    "${android.os.Environment.DIRECTORY_PICTURES}/Marginalia",
                )
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
            }
            val target = resolver.insert(
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                values,
            ) ?: return false
            try {
                resolver.openOutputStream(target)!!.use { out -> source.inputStream().use { it.copyTo(out) } }
            } catch (_: Exception) {
                resolver.delete(target, null, null)
                return false
            }
            values.clear()
            values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(target, values, null, null)
            target
        } else {
            // Before Android 10, writing to shared Pictures needs a storage permission; the
            // app's own Pictures folder doesn't, and the media scanner still lists it.
            val dir = java.io.File(
                activity.getExternalFilesDir(android.os.Environment.DIRECTORY_PICTURES),
                "Marginalia",
            ).apply { mkdirs() }
            val file = java.io.File(dir, name)
            try {
                source.copyTo(file, overwrite = true)
            } catch (_: Exception) {
                return false
            }
            android.media.MediaScannerConnection.scanFile(activity, arrayOf(file.path), arrayOf("image/png"), null)
            androidx.core.content.FileProvider.getUriForFile(activity, "app.marginalia.files", file)
        }
        val view = android.content.Intent(android.content.Intent.ACTION_VIEW)
            .setDataAndType(uri, "image/png")
            .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        runCatching { activity.startActivity(view) }
        return true
    }

    /** Returns true if the key was used to turn a page. */
    fun onKeyEvent(event: KeyEvent): Boolean {
        if (!volumeKeysTurnPages) return false
        val forward = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_DOWN -> true
            KeyEvent.KEYCODE_VOLUME_UP -> false
            else -> return false
        }
        // Swallow the release and repeats too, so the volume panel never shows.
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            channel.invokeMethod("onVolumeKey", mapOf("forward" to forward))
        }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
