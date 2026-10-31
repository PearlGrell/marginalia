package app.marginalia

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

/**
 * A highlight of the reader's own on the home screen, a different one each day, in the app's
 * paper and ink. Tapping it opens the book at that highlight. The app keeps the highlights to
 * choose from current through [update] (see DeviceChannel's `updateQuotes`); the day's pick is
 * made each time it's drawn (every half hour at most), so it changes at midnight without the
 * app.
 */
class QuoteWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, render(context)) }
    }

    /** One highlight: its words, its book, and where it is (a Readium locator, JSON). */
    internal data class Quote(val text: String, val title: String, val bookId: String, val locator: String?)

    companion object {
        private const val PREFS = "marginalia_quotes"

        /** Saves the highlights to choose from (JSON: `[{text, title, bookId, locator}]`). */
        fun update(context: Context, quotes: List<Map<String, Any?>>) {
            val json = JSONArray(quotes.map { JSONObject(it) })
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("quotes", json.toString())
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, QuoteWidget::class.java)).forEach {
                manager.updateAppWidget(it, render(context))
            }
        }

        internal fun parse(json: String?): List<Quote> {
            if (json.isNullOrBlank()) return emptyList()
            val array = runCatching { JSONArray(json) }.getOrNull() ?: return emptyList()
            return (0 until array.length()).mapNotNull { i ->
                val o = array.optJSONObject(i) ?: return@mapNotNull null
                val text = o.optString("text").trim()
                val bookId = o.optString("bookId")
                if (text.isEmpty() || bookId.isEmpty()) null
                else Quote(text, o.optString("title"), bookId, o.optString("locator").takeIf { it.isNotEmpty() })
            }
        }

        /** The day's highlight: the same all day, the next one tomorrow. */
        internal fun pick(quotes: List<Quote>, epochDay: Long): Quote? =
            if (quotes.isEmpty()) null else quotes[Math.floorMod(epochDay, quotes.size.toLong()).toInt()]

        private fun render(context: Context): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_quote)
            val quotes = parse(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("quotes", null))
            val quote = pick(quotes, java.time.LocalDate.now().toEpochDay())
            val open = if (quote != null) {
                val at = quote.locator?.let { "?at=" + Uri.encode(it) }.orEmpty()
                Intent(Intent.ACTION_VIEW, Uri.parse("marginalia://app/read/${quote.bookId}$at"))
            } else {
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            }.setClass(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(
                android.R.id.background,
                PendingIntent.getActivity(
                    context,
                    1,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            if (quote == null) {
                views.setTextViewText(R.id.quote_text, context.getString(R.string.quote_widget_empty))
                views.setViewVisibility(R.id.quote_book, View.GONE)
                return views
            }
            views.setTextViewText(R.id.quote_text, "“${quote.text}”")
            views.setTextViewText(R.id.quote_book, quote.title)
            views.setViewVisibility(R.id.quote_book, if (quote.title.isBlank()) View.GONE else View.VISIBLE)
            return views
        }
    }
}
