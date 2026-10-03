package app.marginalia.readium

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.Choreographer
import android.view.View
import android.widget.FrameLayout
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.commitNow
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.readium.r2.navigator.DecorableNavigator
import org.readium.r2.navigator.HyperlinkNavigator
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.navigator.input.InputListener
import org.readium.r2.navigator.input.TapEvent
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Href
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.locateProgression
import org.readium.r2.shared.publication.services.search.search
import org.readium.r2.shared.util.AbsoluteUrl

/**
 * One Readium [EpubNavigatorFragment] shown inside a Flutter platform view.
 *
 * Dart drives it through the `marginalia/readium-view/<viewId>` channel:
 * - `goForward`, `goBackward` → bool (false at the start or end of the book). They return once
 *   the new page has been laid out, so Dart can take a snapshot of it straight away.
 * - `goToLocator {locator}`, `goToHref {href}`, `goToProgression {progression}` → bool
 * - `setPreferences {…}` (see [PreferencesMapper])
 * - `setHighlights {highlights: [{id, locator, color}]}` draws the reader's highlights
 * - `setSpokenSentence {locator?, color}` marks the sentence being read aloud
 * - `search {query}` → `[{locator, title, before, match, after, progression}]`;
 *   `markSearchResult {locator?, color}` underlines the one being looked at
 * - `insertTranslation {id, text}` puts a translation after a marked paragraph
 * - `locatorAt {x, y}` → the locator of the paragraph at a tap, or null
 * - `snapshot {scale?}` → `{width, height, pixels}` with RGBA8888 pixels of the visible page,
 *   which the page curl animates.
 *
 * It calls `onLocatorChanged` on Dart whenever the reading position changes, `onTap {x, y}`
 * (fractions of the view) for taps that didn't follow a link, `onSelection {action, locator,
 * text, before, after, paragraphId?, paragraphText?}` for the selection menu,
 * `onHighlightTapped {id}`, and `onFootnote {html, href}` instead of jumping to a footnote.
 */
@OptIn(ExperimentalReadiumApi::class)
class ReaderPlatformView(
    private val activity: FragmentActivity,
    messenger: BinaryMessenger,
    viewId: Int,
    private val publication: Publication,
    private val initialLocator: Locator?,
    initialPreferences: Map<String, Any?>,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val channel = MethodChannel(messenger, "${ReaderViewFactory.VIEW_TYPE}/$viewId")
    private val fragmentTag = "$FRAGMENT_TAG_PREFIX$viewId"

    private var preferences = PreferencesMapper.fromMap(initialPreferences)
    private var backgroundColor = PreferencesMapper.backgroundColor(initialPreferences)

    private val container = FrameLayout(activity).apply {
        id = View.generateViewId()
        setBackgroundColor(backgroundColor)
    }

    private var navigator: EpubNavigatorFragment? = null
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
        // The fragment manager looks the container up by id, so it must be in the window first.
        container.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {
                if (navigator == null && !disposed) attachNavigator()
            }

            override fun onViewDetachedFromWindow(v: View) {}
        })
    }

    override fun getView(): View = container

    private fun attachNavigator() {
        val factory = EpubNavigatorFactory(publication).createFragmentFactory(
            initialLocator = initialLocator,
            initialPreferences = preferences,
            listener = object : EpubNavigatorFragment.Listener {
                // Footnotes open as a popup in Flutter instead of jumping to the note.
                override fun shouldFollowInternalLink(
                    link: Link,
                    context: HyperlinkNavigator.LinkContext?,
                ): Boolean {
                    if (context is HyperlinkNavigator.FootnoteContext) {
                        channel.invokeMethod(
                            "onFootnote",
                            mapOf("html" to context.noteContent, "href" to link.href.toString()),
                        )
                        return false
                    }
                    return true
                }

                override fun onExternalLinkActivated(url: AbsoluteUrl) {
                    val view = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url.toString()))
                    runCatching { activity.startActivity(view) }
                }
            },
            configuration = ReadingFonts.configuration().apply {
                selectionActionModeCallback = SelectionMenu(
                    onAction = ::onSelectionAction,
                    onActiveChanged = { active ->
                        channel.invokeMethod("onSelectionActive", mapOf("active" to active))
                    },
                )
            },
        )
        val fragment = factory.instantiate(
            activity.classLoader,
            EpubNavigatorFragment::class.java.name,
        ) as EpubNavigatorFragment

        activity.supportFragmentManager.commitNow(allowStateLoss = true) {
            add(container.id, fragment, fragmentTag)
        }
        navigator = fragment

        fragment.currentLocator
            .onEach { channel.invokeMethod("onLocatorChanged", it.toEventMap()) }
            .launchIn(scope)

        fragment.addDecorationListener(
            HIGHLIGHTS,
            object : DecorableNavigator.Listener {
                override fun onDecorationActivated(
                    event: DecorableNavigator.OnActivatedEvent,
                ): Boolean {
                    channel.invokeMethod("onHighlightTapped", mapOf("id" to event.decoration.id))
                    return true
                }
            },
        )

        // Flutter hands plain taps to this view (so links work); Readium reports the ones
        // that didn't follow a link, and Dart decides what they do (turn, show controls).
        fragment.addInputListener(object : InputListener {
            override fun onTap(event: TapEvent): Boolean {
                val view = fragment.view ?: return false
                if (view.width == 0 || view.height == 0) return false
                channel.invokeMethod(
                    "onTap",
                    mapOf("x" to event.point.x / view.width, "y" to event.point.y / view.height),
                )
                return true
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val navigator = navigator
        if (navigator == null) {
            result.error("not_ready", "The reader is not attached yet", null)
            return
        }
        when (call.method) {
            "goForward" -> navigate(result) { navigator.goForward(animated = false) }
            "goBackward" -> navigate(result) { navigator.goBackward(animated = false) }
            "goToLocator" -> {
                val json = call.argument<String>("locator")
                val locator = json?.let { Locator.fromJSON(JSONObject(it)) }
                    ?: return result.error("bad_args", "locator is invalid", null)
                navigate(result) { navigator.go(locator, animated = false) }
            }
            "goToHref" -> {
                val href = call.argument<String>("href")?.let { Href(it) }
                    ?: return result.error("bad_args", "href is invalid", null)
                navigate(result) { navigator.go(Link(href = href), animated = false) }
            }
            "goToProgression" -> {
                val progression = call.argument<Double>("progression")
                    ?: return result.error("bad_args", "progression is required", null)
                scope.launch {
                    val locator = publication.locateProgression(progression)
                    if (locator == null) {
                        result.success(false)
                    } else {
                        navigate(result) { navigator.go(locator, animated = false) }
                    }
                }
            }
            "setPreferences" -> {
                @Suppress("UNCHECKED_CAST")
                val map = call.arguments as? Map<String, Any?> ?: emptyMap()
                preferences = PreferencesMapper.fromMap(map)
                backgroundColor = PreferencesMapper.backgroundColor(map)
                container.setBackgroundColor(backgroundColor)
                navigator.submitPreferences(preferences)
                result.success(null)
            }
            "snapshot" -> snapshot(call.argument<Double>("scale") ?: 1.0, result)
            "setSpokenSentence" -> {
                // While reading aloud: mark the sentence and keep it on screen.
                val locator = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
                val tint = (call.argument<Number>("color"))?.toInt() ?: 0
                scope.launch {
                    navigator.applyDecorations(
                        listOfNotNull(
                            locator?.let {
                                Decoration("spoken", it, Decoration.Style.Highlight(tint = tint))
                            },
                        ),
                        SPOKEN,
                    )
                    if (locator != null) navigator.go(locator, animated = false)
                    result.success(null)
                }
            }
            "search" -> {
                val query = call.argument<String>("query")?.trim().orEmpty()
                if (query.isEmpty()) return result.success(emptyList<Any>())
                scope.launch {
                    val iterator = publication.search(query)
                        ?: return@launch result.success(emptyList<Any>())
                    val found = mutableListOf<Map<String, Any?>>()
                    try {
                        while (found.size < MAX_SEARCH_RESULTS) {
                            val page = iterator.next().getOrNull() ?: break
                            if (page.locators.isEmpty()) break
                            page.locators.forEach { found += it.toSearchMap() }
                        }
                    } finally {
                        iterator.close()
                    }
                    result.success(found.take(MAX_SEARCH_RESULTS))
                }
            }
            "markSearchResult" -> {
                val locator = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
                val tint = call.argument<Number>("color")?.toInt() ?: 0
                scope.launch {
                    navigator.applyDecorations(
                        listOfNotNull(
                            locator?.let { Decoration("search", it, Decoration.Style.Underline(tint = tint)) },
                        ),
                        SEARCH,
                    )
                    result.success(null)
                }
            }
            "locatorAt" -> {
                // The paragraph under a tap (fractions of the view), as a locator listening
                // can start from: the page's locator, narrowed to that element.
                val x = call.argument<Double>("x") ?: return result.success(null)
                val y = call.argument<Double>("y") ?: return result.success(null)
                scope.launch {
                    val found = navigator.evaluateJavascript(
                        LINE_AT_SCRIPT.replace("%X%", x.toString()).replace("%Y%", y.toString()),
                    )?.let { raw ->
                        runCatching { JSONObject(JSONObject("{\"v\":$raw}").getString("v")) }.getOrNull()
                    }
                    if (found == null) return@launch result.success(null)
                    val page = navigator.currentLocator.value
                    val locator = page.copy(
                        locations = page.locations.copy(
                            otherLocations = page.locations.otherLocations + ("cssSelector" to found.getString("selector")),
                        ),
                        text = Locator.Text(highlight = found.optString("text")),
                    )
                    result.success(locator.toJSON().toString())
                }
            }
            "insertTranslation" -> {
                val id = call.argument<String>("id")
                val translation = call.argument<String>("text")
                if (id == null || translation == null) return result.success(false)
                val script = """
                    (function () {
                      var el = document.querySelector('[data-marginalia-p="' + ${JSONObject.quote(id)} + '"]');
                      if (!el) return false;
                      var old = el.nextElementSibling;
                      if (old && old.classList.contains('marginalia-translation')) old.remove();
                      var div = document.createElement('div');
                      div.className = 'marginalia-translation';
                      div.textContent = ${JSONObject.quote(translation)};
                      div.style.cssText = 'margin:0.4em 0 1em;padding:0.4em 0.8em;border-left:3px solid #A23B34;font-style:italic;opacity:0.85;';
                      el.insertAdjacentElement('afterend', div);
                      return true;
                    })();
                """.trimIndent()
                scope.launch { result.success(navigator.evaluateJavascript(script) == "true") }
            }
            "setHighlights" -> {
                @Suppress("UNCHECKED_CAST")
                val list = call.argument<List<Map<String, Any?>>>("highlights").orEmpty()
                val decorations = list.mapNotNull { item ->
                    val locator = (item["locator"] as? String)
                        ?.let { Locator.fromJSON(JSONObject(it)) }
                        ?: return@mapNotNull null
                    Decoration(
                        id = item["id"] as String,
                        locator = locator,
                        style = Decoration.Style.Highlight(
                            tint = (item["color"] as Number).toInt(),
                        ),
                    )
                }
                scope.launch {
                    navigator.applyDecorations(decorations, HIGHLIGHTS)
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** A Highlight, Note, Define or Copy picked from the selection menu. */
    private fun onSelectionAction(action: String) {
        val navigator = navigator ?: return
        scope.launch {
            val selection = navigator.currentSelection() ?: return@launch
            // For translating: mark the paragraph around the selection, so a translation can
            // be put right after it.
            val paragraph = if (action == "translate") {
                navigator.evaluateJavascript(PARAGRAPH_SCRIPT)?.let {
                    runCatching { JSONObject(JSONObject("{\"v\":$it}").getString("v")) }.getOrNull()
                }
            } else {
                null
            }
            navigator.clearSelection()
            val text = selection.locator.text
            channel.invokeMethod(
                "onSelection",
                mapOf(
                    "action" to action,
                    "locator" to selection.locator.toJSON().toString(),
                    "text" to text.highlight,
                    "before" to text.before,
                    "after" to text.after,
                    "chapterTitle" to selection.locator.title,
                    "progression" to selection.locator.locations.totalProgression,
                    "paragraphId" to paragraph?.optString("id"),
                    "paragraphText" to paragraph?.optString("text"),
                ),
            )
        }
    }

    /**
     * Runs a navigation, then waits until the new page is reported and drawn, so a snapshot
     * taken right after shows it.
     */
    private fun navigate(result: MethodChannel.Result, go: suspend () -> Boolean) {
        val navigator = navigator ?: return result.success(false)
        scope.launch {
            val before = navigator.currentLocator.value
            // Readium's goForward/goBackward report true even at the end or start of the book,
            // so a move only counts once the reported position changes.
            val moved = go() && withTimeoutOrNull(SETTLE_TIMEOUT_MS) {
                navigator.currentLocator.drop(1).first { it != before }
            } != null
            if (moved) awaitFrames(2)
            result.success(moved)
        }
    }

    private fun snapshot(scale: Double, result: MethodChannel.Result) {
        val view = navigator?.view ?: container
        val width = (view.width * scale).toInt()
        val height = (view.height * scale).toInt()
        if (width <= 0 || height <= 0) {
            result.error("not_laid_out", "The reader has no size yet", null)
            return
        }
        // Drawing the WebView into a software canvas is fast enough for a page (a few ms on
        // recent phones). PixelCopy from the window is the fallback if this proves slow.
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(backgroundColor)
        canvas.scale(scale.toFloat(), scale.toFloat())
        view.draw(canvas)

        val buffer = ByteBuffer.allocate(bitmap.byteCount)
        bitmap.copyPixelsToBuffer(buffer)
        bitmap.recycle()
        result.success(
            mapOf("width" to width, "height" to height, "pixels" to buffer.array()),
        )
    }

    override fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        scope.cancel()
        val fragment = activity.supportFragmentManager.findFragmentByTag(fragmentTag)
        if (fragment != null && !activity.isDestroyed) {
            activity.supportFragmentManager.commitNow(allowStateLoss = true) { remove(fragment) }
        }
        navigator = null
    }

    companion object {
        const val FRAGMENT_TAG_PREFIX = "marginalia-reader-"
        private const val HIGHLIGHTS = "highlights"
        private const val SPOKEN = "spoken"
        private const val SEARCH = "search"
        private const val MAX_SEARCH_RESULTS = 300

        /** Marks the paragraph around the selection; returns {id, text} as JSON. */
        private val PARAGRAPH_SCRIPT = """
            (function () {
              var s = window.getSelection();
              if (!s || !s.rangeCount) return null;
              var n = s.anchorNode;
              var el = (n.nodeType === 1 ? n : n.parentElement).closest('p, li, blockquote, h1, h2, h3, h4, dd, div');
              if (!el) return null;
              var id = el.getAttribute('data-marginalia-p') || ('p' + Date.now());
              el.setAttribute('data-marginalia-p', id);
              return JSON.stringify({ id: id, text: el.innerText });
            })();
        """.trimIndent()
        private const val SETTLE_TIMEOUT_MS = 1500L

        /** The block of text at (%X%, %Y%), fractions of the page: {selector, text}, or null. */
        private val LINE_AT_SCRIPT = """
            (function () {
              var el = document.elementFromPoint(window.innerWidth * %X%, window.innerHeight * %Y%);
              if (!el) return null;
              var block = el.closest('p, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, figcaption, td, pre');
              if (!block) block = el;
              var text = (block.innerText || '').trim();
              if (!text || block === document.body || block === document.documentElement) return null;
              var parts = [];
              for (var n = block; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
                var i = 1;
                for (var s = n.previousElementSibling; s; s = s.previousElementSibling) i++;
                parts.unshift(n.tagName.toLowerCase() + ':nth-child(' + i + ')');
              }
              return JSON.stringify({ selector: 'body > ' + parts.join(' > '), text: text.substring(0, 200) });
            })();
        """.trimIndent()
    }
}

private suspend fun awaitFrames(count: Int) {
    repeat(count) {
        suspendCancellableCoroutine { cont ->
            Choreographer.getInstance().postFrameCallback { cont.resume(Unit) }
        }
    }
}

private fun Locator.toSearchMap(): Map<String, Any?> = mapOf(
    "locator" to toJSON().toString(),
    "title" to title,
    "before" to text.before,
    "match" to text.highlight,
    "after" to text.after,
    "progression" to locations.totalProgression,
)

private fun Locator.toEventMap(): Map<String, Any?> = mapOf(
    "locator" to toJSON().toString(),
    "href" to href.toString(),
    "title" to title,
    "progression" to locations.progression,
    "totalProgression" to locations.totalProgression,
    "position" to locations.position,
)
