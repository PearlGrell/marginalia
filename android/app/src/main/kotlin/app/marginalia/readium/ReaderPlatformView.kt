package app.marginalia.readium

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.view.Choreographer
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentFactory
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
import org.readium.r2.navigator.OverflowableNavigator
import org.readium.r2.navigator.image.ImageNavigatorFragment
import org.readium.r2.navigator.pdf.PdfNavigatorFactory
import org.readium.r2.navigator.pdf.PdfNavigatorFragment
import org.readium.adapter.pdfium.navigator.PdfiumEngineProvider
import org.readium.adapter.pdfium.navigator.PdfiumPreferences
import org.readium.r2.navigator.preferences.Fit
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
import org.readium.r2.shared.publication.html.cssSelector
import org.readium.r2.shared.publication.services.locateProgression
import org.readium.r2.shared.publication.services.search.search
import org.readium.r2.shared.util.AbsoluteUrl

/**
 * One Readium navigator shown inside a Flutter platform view: an [EpubNavigatorFragment] for
 * EPUB, Readium's PDF navigator (PDFium) for PDF, and its image navigator for comics. Turning,
 * going to a place, the position and snapshots work for all three; what needs the text
 * (highlights, the spoken sentence, search, the line under a tap, translations, selection)
 * is EPUB's alone, and does nothing for the others.
 *
 * Dart drives it through the `marginalia/readium-view/<viewId>` channel:
 * - `goForward`, `goBackward` → bool (false at the start or end of the book). They return once
 *   the new page has been laid out, so Dart can take a snapshot of it straight away.
 * - `goToLocator {locator}`, `goToHref {href}`, `goToProgression {progression}` → bool
 * - `setPreferences {…}` (see [PreferencesMapper])
 * - `setHighlights {highlights: [{id, locator, color}]}` draws the reader's highlights
 * - `setSpokenSentence {locator?, color, follow}` marks the sentence being read aloud and,
 *   with `follow`, turns (or scrolls) to it when it isn't on screen
 * - `search {query}` → `[{locator, title, before, match, after, progression}]`;
 *   `markSearchResult {locator?, color}` underlines the one being looked at
 * - `insertTranslation {id, text}` puts a translation after a marked paragraph
 * - `clearSelection` ends the selection (a tap elsewhere, without using its menu)
 * - `locatorAt {x, y}` → the locator of the sentence at a tap (its paragraph, with the
 *   sentence as the text), or null; `firstVisibleSentence` → the same for the first sentence
 *   that starts on the page
 * - `snapshot {scale?}` → `{width, height, pixels}` with RGBA8888 pixels of the visible page,
 *   which the page curl animates.
 *
 * It calls `onLocatorChanged` on Dart whenever the reading position changes, `onTap {x, y}`
 * (fractions of the view) for taps that didn't follow a link, `onSelection {action, locator,
 * text, before, after, paragraphId?, paragraphText?, pageContext?}` for the selection menu,
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
    /** The menu over selected text; kept so a selection cleared from Flutter closes it too. */
    private val selectionMenu = SelectionMenu(
        onAction = ::onSelectionAction,
        onActiveChanged = { active -> channel.invokeMethod("onSelectionActive", mapOf("active" to active)) },
    )
    private val fragmentTag = "$FRAGMENT_TAG_PREFIX$viewId"

    private var preferences = PreferencesMapper.fromMap(initialPreferences)
    private var backgroundColor = PreferencesMapper.backgroundColor(initialPreferences)

    private val container = FrameLayout(activity).apply {
        id = View.generateViewId()
        setBackgroundColor(backgroundColor)
    }

    /** The navigator, whatever the book. */
    private var visual: OverflowableNavigator? = null

    /** The EPUB navigator, for what needs the text; null for PDF and comics. */
    private var navigator: EpubNavigatorFragment? = null
    private var disposed = false

    init {
        channel.setMethodCallHandler(this)
        // The fragment manager looks the container up by id, so it must be in the window first.
        container.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {
                if (visual == null && !disposed) attachNavigator()
            }

            override fun onViewDetachedFromWindow(v: View) {}
        })
    }

    override fun getView(): View = container

    private fun attachNavigator() {
        val fragment = when (publication.format()) {
            "pdf" -> instantiate(
                PdfNavigatorFactory(publication, PdfiumEngineProvider())
                    .createFragmentFactory(initialLocator = initialLocator, initialPreferences = PdfiumPreferences(fit = Fit.WIDTH)),
                PdfNavigatorFragment::class.java,
            )
            "comic" -> instantiate(
                ImageNavigatorFragment.createFactory(publication, initialLocator),
                ImageNavigatorFragment::class.java,
            )
            else -> instantiate(epubFactory(), EpubNavigatorFragment::class.java)
        }
        activity.supportFragmentManager.commitNow(allowStateLoss = true) {
            add(container.id, fragment, fragmentTag)
        }
        val visual = fragment as OverflowableNavigator
        this.visual = visual
        navigator = fragment as? EpubNavigatorFragment

        visual.currentLocator
            .onEach { channel.invokeMethod("onLocatorChanged", it.toEventMap()) }
            .launchIn(scope)

        navigator?.addDecorationListener(
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
        visual.addInputListener(object : InputListener {
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

    private fun <T : Fragment> instantiate(factory: FragmentFactory, type: Class<T>): Fragment =
        factory.instantiate(activity.classLoader, type.name)

    private fun epubFactory(): FragmentFactory =
        EpubNavigatorFactory(publication).createFragmentFactory(
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
                // Flutter's band above the page already clears the notch; Readium adding it
                // again doubled the space over the text.
                shouldApplyInsetsPadding = false
                selectionActionModeCallback = selectionMenu
            },
        )

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val visual = visual
        if (visual == null) {
            result.error("not_ready", "The reader is not attached yet", null)
            return
        }
        when (call.method) {
            "goForward" -> return navigate(result) { visual.goForward(animated = false) }
            "goBackward" -> return navigate(result) { visual.goBackward(animated = false) }
            "goToLocator" -> {
                val json = call.argument<String>("locator")
                val locator = json?.let { Locator.fromJSON(JSONObject(it)) }
                    ?: return result.error("bad_args", "locator is invalid", null)
                return navigate(result) { visual.go(locator, animated = false) }
            }
            "goToHref" -> {
                val href = call.argument<String>("href")?.let { Href(it) }
                    ?: return result.error("bad_args", "href is invalid", null)
                return navigate(result) { visual.go(Link(href = href), animated = false) }
            }
            "goToProgression" -> {
                val progression = call.argument<Double>("progression")
                    ?: return result.error("bad_args", "progression is required", null)
                scope.launch {
                    val locator = publication.locateProgression(progression)
                    if (locator == null) {
                        result.success(false)
                    } else {
                        navigate(result) { visual.go(locator, animated = false) }
                    }
                }
                return
            }
            "snapshot" -> return snapshot(call.argument<Double>("scale") ?: 1.0, result)
            "search" -> return search(call.argument<String>("query")?.trim().orEmpty(), result)
        }
        // The rest needs the text: EPUB only.
        val navigator = navigator ?: return result.success(
            when (call.method) {
                "locatorAt", "firstVisibleSentence" -> null
                "insertTranslation" -> false
                else -> null
            },
        )
        when (call.method) {
            "setPreferences" -> {
                @Suppress("UNCHECKED_CAST")
                val map = call.arguments as? Map<String, Any?> ?: emptyMap()
                preferences = PreferencesMapper.fromMap(map)
                backgroundColor = PreferencesMapper.backgroundColor(map)
                container.setBackgroundColor(backgroundColor)
                navigator.submitPreferences(preferences)
                result.success(null)
            }
            "setSpokenSentence" -> {
                // While reading aloud: mark the sentence and keep it on screen.
                val locator = call.argument<String>("locator")?.let { Locator.fromJSON(JSONObject(it)) }
                val tint = (call.argument<Number>("color"))?.toInt() ?: 0
                val follow = call.argument<Boolean>("follow") ?: true
                scope.launch {
                    navigator.applyDecorations(
                        listOfNotNull(
                            locator?.let {
                                Decoration("spoken", it, Decoration.Style.Highlight(tint = tint))
                            },
                        ),
                        SPOKEN,
                    )
                    if (locator != null && follow) keepInView(navigator, locator)
                    result.success(null)
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
                // The sentence under a tap (fractions of the view), as a locator listening can
                // start from: the page's locator, narrowed to its paragraph.
                val x = call.argument<Double>("x") ?: return result.success(null)
                val y = call.argument<Double>("y") ?: return result.success(null)
                // Readium's tap points are in its own view, which pads the page: find the spot
                // in the page's web view, where the script looks.
                val (wx, wy) = webFractions(x, y) ?: (x to y)
                scope.launch {
                    val script = LINE_AT_SCRIPT.replace("%X%", wx.toString()).replace("%Y%", wy.toString())
                    result.success(sentenceLocator(navigator, script)?.toJSON()?.toString())
                }
            }
            "firstVisibleSentence" -> scope.launch {
                result.success(sentenceLocator(navigator, FIRST_VISIBLE_SCRIPT)?.toJSON()?.toString())
            }
            "clearSelection" -> {
                navigator.clearSelection()
                selectionMenu.finish()
                scope.launch { clearAllSelections() }
                result.success(null)
            }
            "hasSelection" -> scope.launch {
                // What the page has selected, not whether a menu says so: a menu whose page went
                // away can be left counted open, and Flutter would keep waiting for it to close.
                val selected = anySelection()
                if (!selected) {
                    if (selectionMenu.isOpen) selectionMenu.finish()
                    endStuckSelecting()
                }
                result.success(selected)
            }
            "clearStaleSelection" -> scope.launch {
                // A tap the page didn't answer: Readium drops taps while text is selected, or
                // while it still believes some is. Whatever was left is cleared; true if anything
                // was, so Flutter does what the tap would have done.
                val cleared = clearAllSelections()
                val unstuck = endStuckSelecting()
                if (selectionMenu.isOpen) selectionMenu.finish()
                result.success(cleared || unstuck)
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

    /**
     * Runs [script], which finds a sentence in the page (`{selector, text, sentence}`), and
     * makes it a locator: the page's, narrowed to the sentence's paragraph, with the sentence
     * as its text.
     */
    private suspend fun sentenceLocator(navigator: EpubNavigatorFragment, script: String): Locator? {
        val found = navigator.evaluateJavascript(script)?.let { raw ->
            runCatching { JSONObject(JSONObject("{\"v\":$raw}").getString("v")) }.getOrNull()
        } ?: return null
        val page = navigator.currentLocator.value
        return page.copy(
            locations = page.locations.copy(
                otherLocations = page.locations.otherLocations + ("cssSelector" to found.getString("selector")),
            ),
            text = Locator.Text(highlight = found.optString("sentence").ifEmpty { found.optString("text") }),
        )
    }

    /** ([x], [y]), fractions of the navigator's view, as fractions of the web view under it. */
    private fun webFractions(x: Double, y: Double): Pair<Double, Double>? {
        val root = navigator?.view ?: return null
        val origin = IntArray(2).also(root::getLocationInWindow)
        val px = origin[0] + x * root.width
        val py = origin[1] + y * root.height
        val visible = Rect()
        val web = webViews(root).firstOrNull {
            it.isShown && it.getGlobalVisibleRect(visible) && visible.contains(px.toInt(), py.toInt())
        } ?: return null
        if (web.width == 0 || web.height == 0) return null
        val at = IntArray(2).also(web::getLocationInWindow)
        return (px - at[0]) / web.width to (py - at[1]) / web.height
    }

    private fun webViews(view: View): List<WebView> = when (view) {
        is WebView -> listOf(view)
        is ViewGroup -> (0 until view.childCount).flatMap { webViews(view.getChildAt(it)) }
        else -> emptyList()
    }

    /**
     * Keeps the sentence being read on screen, moving only when it isn't: turns as many pages
     * as it is away (or scrolls it a third of the way down). If it can't be found in the page,
     * goes to it as Readium does.
     */
    private suspend fun keepInView(navigator: EpubNavigatorFragment, locator: Locator) {
        if (locator.href.removeFragment() != navigator.currentLocator.value.href.removeFragment()) {
            navigator.go(locator, animated = false)
            return
        }
        val script = WHERE_IS_SCRIPT
            .replace("%SELECTOR%", JSONObject.quote(locator.locations.cssSelector.orEmpty()))
            .replace("%TEXT%", JSONObject.quote(locator.text.highlight.orEmpty()))
            .replace("%SCROLL%", (preferences.scroll == true).toString())
        val where = navigator.evaluateJavascript(script)?.let { raw ->
            runCatching { JSONObject("{\"v\":$raw}").getString("v") }.getOrNull()
        }
        when (val move = Follow.parse(where)) {
            Follow.Visible -> {}
            is Follow.Pages -> repeat(kotlin.math.abs(move.count)) {
                if (move.count > 0) navigator.goForward(animated = false) else navigator.goBackward(animated = false)
                withTimeoutOrNull(SETTLE_TIMEOUT_MS) { navigator.currentLocator.drop(1).first() }
            }
            is Follow.Scroll -> navigator.evaluateJavascript("window.scrollBy(0, ${move.by});")
            Follow.Unknown -> navigator.go(locator, animated = false)
        }
    }

    /**
     * The page views the navigator has loaded: the page on screen and the chapters either side
     * (a paginated book keeps its neighbours ready). Readium's own clearing reaches only the one
     * it takes for current, which can be another than the one shown, leaving text selected.
     */
    private fun webViews(): List<WebView> {
        val found = mutableListOf<WebView>()
        fun walk(view: View) {
            if (view is WebView) found += view
            if (view is ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk((visual as? Fragment)?.view ?: container)
        return found
    }

    private suspend fun evaluate(view: WebView, script: String): String? =
        suspendCancellableCoroutine { cont -> view.evaluateJavascript(script) { if (cont.isActive) cont.resume(it) } }

    /** Whether text is selected in any of the page views. */
    private suspend fun anySelection(): Boolean =
        webViews().any { evaluate(it, HAS_SELECTION_SCRIPT) == "true" }

    /** Clears the selection in every page view; whether any had one. */
    private suspend fun clearAllSelections(): Boolean {
        var had = false
        for (view in webViews()) {
            if (evaluate(view, CLEAR_SELECTION_SCRIPT) == "true") had = true
        }
        return had
    }

    /**
     * Readium's page view keeps its own "text is selected" flag, set and cleared by the page's
     * script as the selection changes, and drops every tap while it's set. A selection that ends
     * without the script seeing it (the page reloaded under it, the selection cleared from here)
     * leaves the flag set and taps dead. Ends it in every page view with nothing selected;
     * whether any was stuck.
     */
    private suspend fun endStuckSelecting(): Boolean {
        val field = selectingField ?: return false
        var stuck = false
        for (view in webViews()) {
            if (!field.declaringClass.isInstance(view)) continue
            if (evaluate(view, COLLAPSED_SCRIPT) != "true") continue
            runCatching {
                if (field.getBoolean(view)) {
                    field.setBoolean(view, false)
                    stuck = true
                }
            }
        }
        return stuck
    }

    /** A Highlight, Note, Define or Copy picked from the selection menu. */
    private fun onSelectionAction(action: String) {
        val navigator = navigator ?: return
        scope.launch {
            val selection = navigator.currentSelection() ?: return@launch
            // For translating: mark the paragraph around the selection, so a translation can
            // be put right after it. For explaining: the paragraph, for what's around it.
            val paragraph = if (action == "translate" || action == "explain") {
                navigator.evaluateJavascript(PARAGRAPH_SCRIPT)?.let {
                    runCatching { JSONObject(JSONObject("{\"v\":$it}").getString("v")) }.getOrNull()
                }
            } else {
                null
            }
            // For sharing as a page: the paragraphs around the selection, read before it's cleared.
            val pageContext = if (action == "share") navigator.evaluateJavascript(SHARE_CONTEXT_SCRIPT)?.let {
                runCatching { JSONObject("{\"v\":$it}").optString("v").takeIf { v -> v.isNotEmpty() && v != "null" } }.getOrNull()
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
                    "pageContext" to pageContext,
                ),
            )
        }
    }

    /** Every place [query] appears in the book (as far as the book can be searched). */
    private fun search(query: String, result: MethodChannel.Result) {
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

    /**
     * Runs a navigation, then waits until the new page is reported and drawn, so a snapshot
     * taken right after shows it.
     */
    private fun navigate(result: MethodChannel.Result, go: suspend () -> Boolean) {
        val navigator = visual ?: return result.success(false)
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
        val view = (visual as? Fragment)?.view ?: container
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
        visual = null
        navigator = null
    }

    companion object {
        const val FRAGMENT_TAG_PREFIX = "marginalia-reader-"
        private const val HIGHLIGHTS = "highlights"
        private const val SPOKEN = "spoken"
        private const val SEARCH = "search"
        /** Whether the page has text selected (Readium won't report taps while it has). */
        private const val HAS_SELECTION_SCRIPT =
            "(function(){var s=window.getSelection();return !!s&&!s.isCollapsed&&s.toString().trim().length>0;})()"

        /** Whether the page has nothing selected at all (not even blank space). */
        private const val COLLAPSED_SCRIPT =
            "(function(){var s=window.getSelection();return !s||s.isCollapsed;})()"

        /** Readium's page view's "selecting" flag (internal to Readium, so found by name). */
        private val selectingField: java.lang.reflect.Field? by lazy {
            runCatching {
                Class.forName("org.readium.r2.navigator.R2BasicWebView")
                    .getDeclaredField("isSelecting").apply { isAccessible = true }
            }.getOrNull()
        }

        /** Clears the page's selection; says whether there was one. */
        private const val CLEAR_SELECTION_SCRIPT =
            "(function(){var s=window.getSelection();var had=!!s&&!s.isCollapsed;if(s)s.removeAllRanges();" +
                "if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();return had;})()"

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
        /**
         * The selection with the page around it, for sharing it as a page: about 700 characters
         * of whole paragraphs before and after it, as `{p: [[[text, selected], …], …]}` (each
         * paragraph a list of runs, 1 for selected), or null if it isn't in plain paragraphs.
         */
        private val SHARE_CONTEXT_SCRIPT = """
            (function () {
              var s = window.getSelection();
              if (!s || !s.rangeCount) return null;
              var range = s.getRangeAt(0);
              var BLOCKS = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, figcaption, pre';
              var all = Array.prototype.filter.call(document.body.querySelectorAll(BLOCKS), function (b) {
                return !b.querySelector(BLOCKS);
              });
              function blockOf(node) {
                var el = node.nodeType === 1 ? node : node.parentElement;
                return el && el.closest(BLOCKS);
              }
              var i = all.indexOf(blockOf(range.startContainer));
              var j = all.indexOf(blockOf(range.endContainer));
              if (i < 0 || j < i) return null;
              function clean(t) { return t.replace(/\s+/g, ' '); }
              function piece(block, from, to) {
                var r = document.createRange();
                r.selectNodeContents(block);
                if (from) r.setStart(from[0], from[1]);
                if (to) r.setEnd(to[0], to[1]);
                return clean(r.toString());
              }
              var paragraphs = [];
              var budget = 700;
              for (var k = i - 1; k >= 0 && budget > 0; k--) {
                var t = clean(all[k].textContent).trim();
                if (!t) continue;
                paragraphs.unshift([[t, 0]]);
                budget -= t.length;
              }
              for (var k = i; k <= j; k++) {
                var start = k === i ? [range.startContainer, range.startOffset] : null;
                var end = k === j ? [range.endContainer, range.endOffset] : null;
                var runs = [];
                if (start) { var lead = piece(all[k], null, start).replace(/^\s+/, ''); if (lead) runs.push([lead, 0]); }
                var chosen = piece(all[k], start, end);
                if (chosen.trim()) runs.push([chosen, 1]);
                if (end) { var tail = piece(all[k], end, null).replace(/\s+$/, ''); if (tail) runs.push([tail, 0]); }
                if (runs.length) paragraphs.push(runs);
              }
              budget = 700;
              for (var k = j + 1; k < all.length && budget > 0; k++) {
                var t = clean(all[k].textContent).trim();
                if (!t) continue;
                paragraphs.push([[t, 0]]);
                budget -= t.length;
              }
              return JSON.stringify({ p: paragraphs });
            })();
        """.trimIndent()
        private const val SETTLE_TIMEOUT_MS = 1500L

        /**
         * Helpers for the scripts below: a block's selector, and the sentence around an offset
         * in its text.
         */
        private val SENTENCE_HELPERS = """
              var BLOCKS = 'p, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, figcaption, td, pre';
              // Readium starts reading aloud from this selector in the book's own file, so
              // elements the app added to the page don't count.
              function added(el) {
                return el.id === 'marginalia-filters' || el.classList.contains('marginalia-translation');
              }
              function selectorOf(block) {
                var parts = [];
                for (var n = block; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
                  var i = 1;
                  for (var s = n.previousElementSibling; s; s = s.previousElementSibling) if (!added(s)) i++;
                  parts.unshift(n.tagName.toLowerCase() + ':nth-child(' + i + ')');
                }
                return 'body > ' + parts.join(' > ');
              }
              function offsetIn(block, node, offset) {
                var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT), n, at = 0;
                while ((n = walker.nextNode())) {
                  if (n === node) return at + offset;
                  at += n.nodeValue.length;
                }
                return -1;
              }
              var END = /[.!?\u2026\u3002\uFF01\uFF1F]/;
              function sentenceAt(text, at, startingHere) {
                var start = at;
                if (!startingHere) while (start > 0 && !END.test(text[start - 1])) start--;
                var end = at;
                while (end < text.length && !END.test(text[end])) end++;
                return text.substring(start, Math.min(text.length, end + 1)).replace(/\s+/g, ' ').trim();
              }
              function found(block, sentence) {
                var text = (block.textContent || '').replace(/\s+/g, ' ').trim();
                if (!text || block === document.body || block === document.documentElement) return null;
                return JSON.stringify({ selector: selectorOf(block), text: text.substring(0, 200), sentence: sentence.substring(0, 300) });
              }
        """.trimIndent()

        /**
         * The sentence at (%X%, %Y%), fractions of the page's web view:
         * {selector, text, sentence}, or null.
         */
        private val LINE_AT_SCRIPT = """
            (function () {
              $SENTENCE_HELPERS
              var x = window.innerWidth * %X%, y = window.innerHeight * %Y%;
              var el = document.elementFromPoint(x, y);
              if (!el) return null;
              var block = el.closest(BLOCKS) || el;
              var sentence = '';
              var caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
              if (caret && block.contains(caret.startContainer)) {
                var at = offsetIn(block, caret.startContainer, caret.startOffset);
                if (at >= 0) sentence = sentenceAt(block.textContent, at, false);
              }
              return found(block, sentence);
            })();
        """.trimIndent()

        /**
         * The first sentence that starts on the page (not one carried over from the page
         * before): {selector, text, sentence}, or null.
         */
        private val FIRST_VISIBLE_SCRIPT = """
            (function () {
              $SENTENCE_HELPERS
              var w = window.innerWidth, h = window.innerHeight;
              var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
              var range = document.createRange();
              while ((n = walker.nextNode())) {
                var value = n.nodeValue;
                if (!/\S/.test(value)) continue;
                for (var i = 0; i < value.length; i++) {
                  if (/\s/.test(value[i])) continue;
                  range.setStart(n, i);
                  range.setEnd(n, i + 1);
                  var r = range.getBoundingClientRect();
                  if (r.width === 0 && r.height === 0) continue;
                  if (r.right <= 0 || r.left >= w || r.bottom <= 0 || r.top >= h) {
                    // Skip ahead a whole node once it's clearly before the page.
                    if (r.left < 0 || r.bottom <= 0) { range.setStart(n, value.length - 1); range.setEnd(n, value.length);
                      var last = range.getBoundingClientRect();
                      if (last.right <= 0 || last.bottom <= 0) break; }
                    continue;
                  }
                  var block = n.parentElement.closest(BLOCKS) || n.parentElement;
                  var text = block.textContent;
                  var at = offsetIn(block, n, i);
                  if (at < 0) return found(block, '');
                  // Carried over from the page before: start at the next sentence.
                  var before = text.substring(0, at).replace(/\s+$/, '');
                  if (before.length > 0 && !END.test(before[before.length - 1])) {
                    var next = at;
                    while (next < text.length && !END.test(text[next])) next++;
                    while (next < text.length && (END.test(text[next]) || /[\s\u201D\u2019"')\]]/.test(text[next]))) next++;
                    if (next < text.length) return found(block, sentenceAt(text, next, true));
                    continue;
                  }
                  return found(block, sentenceAt(text, at, true));
                }
              }
              return null;
            })();
        """.trimIndent()

        /**
         * Where the sentence %TEXT% (in %SELECTOR%, or anywhere in the chapter) is, from the
         * page on screen: "visible", "page:N" (N pages on, negative for back), "scroll:PX",
         * or "unknown".
         */
        private val WHERE_IS_SCRIPT = """
            (function () {
              var selector = %SELECTOR%, text = %TEXT%, scroll = %SCROLL%;
              var probe = text.replace(/\s+/g, ' ').trim().substring(0, 60);
              if (!probe) return 'unknown';
              function locate(root) {
                if (!root) return null;
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), n;
                var nodes = [], raw = '';
                while ((n = walker.nextNode())) { nodes.push([n, raw.length]); raw += n.nodeValue; }
                // Whitespace-collapsed text, with each character's place in the raw text.
                var flat = '', map = [], space = false;
                for (var i = 0; i < raw.length; i++) {
                  if (/\s/.test(raw[i])) { if (!space) { flat += ' '; map.push(i); } space = true; }
                  else { flat += raw[i]; map.push(i); space = false; }
                }
                var at = flat.indexOf(probe);
                if (at < 0) return null;
                var start = map[at], node = null, off = 0;
                for (var k = 0; k < nodes.length; k++) {
                  if (nodes[k][1] <= start) { node = nodes[k][0]; off = nodes[k][1]; } else break;
                }
                if (!node) return null;
                var range = document.createRange();
                var o = Math.min(start - off, node.nodeValue.length - 1);
                range.setStart(node, o);
                range.setEnd(node, o + 1);
                var rects = range.getClientRects();
                return rects.length ? rects[0] : range.getBoundingClientRect();
              }
              var root = null;
              try { root = selector ? document.querySelector(selector) : null; } catch (e) {}
              var r = locate(root) || locate(document.body);
              if (!r) return 'unknown';
              var w = window.innerWidth, h = window.innerHeight;
              if (scroll) {
                if (r.top >= 0 && r.bottom <= h * 0.9) return 'visible';
                return 'scroll:' + Math.round(r.top - h / 3);
              }
              var page = Math.floor((r.left + 1) / w);
              var rtl = getComputedStyle(document.documentElement).direction === 'rtl' ||
                getComputedStyle(document.body).direction === 'rtl';
              if (rtl) page = -page;
              return page === 0 ? 'visible' : 'page:' + page;
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

/** What keeping the spoken sentence on screen takes, from the page's `WHERE_IS_SCRIPT`. */
internal sealed interface Follow {
    data object Visible : Follow

    data class Pages(val count: Int) : Follow

    data class Scroll(val by: Int) : Follow

    data object Unknown : Follow

    companion object {
        /** Further than a few pages away, going straight there beats turning one by one. */
        private const val MAX_TURNS = 3

        fun parse(where: String?): Follow = when {
            where == "visible" -> Visible
            where?.startsWith("page:") == true ->
                where.removePrefix("page:").toIntOrNull()
                    ?.takeIf { it != 0 && kotlin.math.abs(it) <= MAX_TURNS }
                    ?.let(::Pages)
                    ?: if (where == "page:0") Visible else Unknown
            where?.startsWith("scroll:") == true -> where.removePrefix("scroll:").toIntOrNull()?.let(::Scroll) ?: Unknown
            else -> Unknown
        }
    }
}
