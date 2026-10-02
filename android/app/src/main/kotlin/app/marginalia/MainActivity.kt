package app.marginalia

import android.os.Bundle
import android.view.KeyEvent
import androidx.fragment.app.commitNow
import app.marginalia.library.LibraryChannel
import app.marginalia.listen.ListenChannel
import app.marginalia.listen.VoicesChannel
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
    private var voicesChannel: VoicesChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Reader fragments are hosted inside Flutter platform views, which do not survive
        // process death. Restore them with Readium's dummy factory, then drop them: the Dart
        // side reopens the book when its platform view is recreated.
        if (savedInstanceState != null) {
            supportFragmentManager.fragmentFactory = EpubNavigatorFragment.createDummyFactory()
        }
        super.onCreate(savedInstanceState)
        val stale = supportFragmentManager.fragments.filter {
            it.tag?.startsWith(ReaderPlatformView.FRAGMENT_TAG_PREFIX) == true
        }
        if (stale.isNotEmpty()) {
            supportFragmentManager.commitNow(allowStateLoss = true) {
                stale.forEach { remove(it) }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        repository = PublicationRepository(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        readiumChannel = ReadiumChannel(messenger, repository)
        deviceChannel = DeviceChannel(messenger, this)
        libraryChannel = LibraryChannel(messenger, this, repository)
        listenChannel = ListenChannel(messenger, this, repository)
        voicesChannel = VoicesChannel(messenger, this)
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
        voicesChannel?.dispose()
        voicesChannel = null
        repository.closeAll()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
