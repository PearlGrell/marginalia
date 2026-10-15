package app.marginalia

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import androidx.fragment.app.commitNow
import app.marginalia.library.LibraryChannel
import app.marginalia.listen.ListenChannel
import app.marginalia.readium.PublicationRepository
import app.marginalia.readium.ReadiumChannel
import app.marginalia.readium.ReaderPlatformView
import app.marginalia.readium.ReaderViewFactory
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import org.readium.r2.navigator.epub.EpubNavigatorFragment

/**
 * Readium's navigator is a Fragment, so the activity must be a FragmentActivity.
 */
class MainActivity : FlutterFragmentActivity() {

    private lateinit var repository: PublicationRepository
    private var readiumChannel: ReadiumChannel? = null
    private var deviceChannel: DeviceChannel? = null
    private var libraryChannel: LibraryChannel? = null
    private var listenChannel: ListenChannel? = null
    private var companionChannel: CompanionChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Reader fragments are hosted inside Flutter platform views, which do not survive
        // process death. Restore them with Readium's dummy factory, then drop them: the Dart
        // side reopens the book when its platform view is recreated.
        if (savedInstanceState != null) {
            supportFragmentManager.fragmentFactory = EpubNavigatorFragment.createDummyFactory()
        }
        super.onCreate(savedInstanceState)
        // Full screen while reading, the page goes up beside the notch (the reader keeps the
        // clock there) instead of stopping under a black strip. Android 15+ does this anyway.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = android.view.WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        // Listen used to read with Kokoro, a 330 MB voice model downloaded into the app; it now
        // uses the phone's own voices, so any copy left behind goes.
        java.io.File(filesDir, "kokoro").takeIf { it.exists() }?.let { kokoro ->
            Thread { kokoro.deleteRecursively() }.start()
        }
        // Gemma used to run with LiteRT-LM from a .litertlm file (557 MB); it's a .task file
        // now, so an old one, and the weight cache made beside it, go.
        java.io.File(filesDir, "models").listFiles { f -> f.name.contains(".litertlm") }?.let { old ->
            Thread { old.forEach { it.delete() } }.start()
        }
        val stale = supportFragmentManager.fragments.filter {
            it.tag?.startsWith(ReaderPlatformView.FRAGMENT_TAG_PREFIX) == true
        }
        if (stale.isNotEmpty()) {
            supportFragmentManager.commitNow(allowStateLoss = true) {
                stale.forEach { remove(it) }
            }
        }
        if (savedInstanceState == null) pendingFile = openedFile(intent)
        deliverPendingFile()
    }

    /** A file to open that arrived before the library channel was there. */
    private var pendingFile: Uri? = null

    private fun deliverPendingFile() {
        val channel = libraryChannel ?: return
        pendingFile?.let(channel::opened)
        pendingFile = null
    }

    /** A book file another app asked to open ("Open with Marginalia"), if [intent] is one. */
    private fun openedFile(intent: Intent?): Uri? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        return uri.takeIf { it.scheme == "content" || it.scheme == "file" }
    }

    override fun onNewIntent(intent: Intent) {
        // A file isn't a route: Flutter's deep linking would show it as a missing page.
        val file = openedFile(intent)
        if (file != null) {
            setIntent(intent)
            libraryChannel?.opened(file)
            return
        }
        super.onNewIntent(intent)
    }

    /** Only marginalia:// links are routes in the app. */
    override fun shouldHandleDeeplinking(): Boolean = openedFile(intent) == null && super.shouldHandleDeeplinking()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        repository = PublicationRepository(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        readiumChannel = ReadiumChannel(messenger, repository)
        deviceChannel = DeviceChannel(messenger, this)
        libraryChannel = LibraryChannel(messenger, this, repository)
        deliverPendingFile()
        listenChannel = ListenChannel(messenger, this, repository)
        companionChannel = CompanionChannel(messenger, applicationContext)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            ReaderViewFactory.VIEW_TYPE,
            ReaderViewFactory(this, messenger, repository),
        )
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        deviceChannel?.onKeyEvent(event) == true || super.dispatchKeyEvent(event)

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        readiumChannel?.dispose()
        readiumChannel = null
        deviceChannel?.dispose()
        deviceChannel = null
        libraryChannel?.dispose()
        libraryChannel = null
        listenChannel?.dispose()
        listenChannel = null
        companionChannel?.dispose()
        companionChannel = null
        repository.closeAll()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
