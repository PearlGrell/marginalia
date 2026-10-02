package app.marginalia.readium

import android.content.Context
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator

/**
 * Creates [ReaderPlatformView]s for `AndroidView(viewType: 'marginalia/readium-view')`.
 *
 * Creation params: `publicationId` (from `ReadiumChannel.open`), optional `locator` (Readium
 * Locator JSON string) and `preferences` (see [PreferencesMapper]).
 */
class ReaderViewFactory(
    private val activity: FragmentActivity,
    private val messenger: BinaryMessenger,
    private val repository: PublicationRepository,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?> ?: emptyMap()
        val publicationId = params["publicationId"] as? String
            ?: throw IllegalArgumentException("publicationId is required")
        val publication = repository.get(publicationId)
            ?: throw IllegalStateException("Publication $publicationId is not open")

        val locator = (params["locator"] as? String)?.let { Locator.fromJSON(JSONObject(it)) }
        @Suppress("UNCHECKED_CAST")
        val preferences = params["preferences"] as? Map<String, Any?> ?: emptyMap()

        return ReaderPlatformView(
            activity = activity,
            messenger = messenger,
            viewId = viewId,
            publication = publication,
            initialLocator = locator,
            initialPreferences = preferences,
        )
    }

    companion object {
        const val VIEW_TYPE = "marginalia/readium-view"
    }
}
