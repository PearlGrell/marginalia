package app.marginalia

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews

/**
 * "Continue reading" on the home screen: the book read last, with its cover and progress, in
 * the app's own paper and ink. Tapping it opens the book. It has a one-row layout for when
 * it's one cell tall. The app keeps it current through [update]
 * (see DeviceChannel's `updateWidget`), so it never wakes the app itself. The streak line
 * ([updateStatus]) is worked out again each time it's drawn (every half hour at most), so
 * it's right after midnight without the app.
 */
class ContinueReadingWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { manager.updateAppWidget(it, views(context, manager.getAppWidgetOptions(it))) }
    }

    /** Resized: before Android 12 the layout is picked here. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        options: Bundle,
    ) {
        manager.updateAppWidget(id, views(context, options))
    }

    /** The streak line: its words, and whether a streak is going (it gets the flame). */
    internal data class Status(val text: String, val streak: Boolean)

    companion object {
        private const val PREFS = "marginalia_widget"

        /** Below this height (dp) the one-row layout is used. */
        private const val TALL_DP = 100f

        /** Saves what the widget shows and redraws every instance of it. */
        fun update(
            context: Context,
            bookId: String?,
            title: String?,
            author: String?,
            progress: Double,
            coverPath: String?,
        ) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("bookId", bookId)
                .putString("title", title)
                .putString("author", author)
                .putFloat("progress", progress.toFloat())
                .putString("coverPath", coverPath)
                .apply()
            redraw(context)
        }

        /**
         * Saves the reading behind the streak line: [todaySeconds] read on [day] (yyyy-mm-dd),
         * the [streak] in days through then, and the daily goal in minutes.
         */
        fun updateStatus(context: Context, day: String, todaySeconds: Int, streak: Int, goalMinutes: Int?) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("day", day)
                .putInt("todaySeconds", todaySeconds)
                .putInt("streak", streak)
                .putInt("goalMinutes", goalMinutes ?: 0)
                .apply()
            redraw(context)
        }

        private fun redraw(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, ContinueReadingWidget::class.java)).forEach {
                manager.updateAppWidget(it, views(context, manager.getAppWidgetOptions(it)))
            }
        }

        /**
         * "5-day streak · 12/30 min today", for today as it is now; "5-day streak · read today"
         * before anything's read today; null when there's nothing to say. Short enough for one
         * line of the widget.
         */
        internal fun statusLine(
            today: java.time.LocalDate,
            day: java.time.LocalDate?,
            todaySeconds: Int,
            streak: Int,
            goalMinutes: Int,
        ): Status? {
            // What was saved is from today, or yesterday (nothing read yet today), or older.
            val minutes = if (day == today) todaySeconds / 60 else 0
            val alive = streak > 0 && (day == today || day == today.minusDays(1))
            val readToday = day == today && todaySeconds >= 60
            val days = if (streak == 1) "1-day streak" else "$streak-day streak"
            if (alive && !readToday) return Status("$days · read today", streak = true)
            val parts = buildList {
                if (alive) add(days)
                if (goalMinutes > 0) add("$minutes/$goalMinutes min today") else if (minutes > 0) add("$minutes min today")
            }
            return parts.takeIf { it.isNotEmpty() }?.let { Status(it.joinToString(" · "), streak = alive) }
        }

        private fun views(context: Context, options: Bundle?): RemoteViews {
            val cover = loadCover(context)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // The launcher picks the layout for each size the widget is shown at.
                return RemoteViews(
                    mapOf(
                        SizeF(180f, 40f) to render(context, R.layout.widget_continue_reading_small, cover),
                        SizeF(180f, TALL_DP) to render(context, R.layout.widget_continue_reading, cover),
                    ),
                )
            }
            val height = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110) ?: 110
            val layout = if (height < TALL_DP) R.layout.widget_continue_reading_small else R.layout.widget_continue_reading
            return render(context, layout, cover)
        }

        private fun loadCover(context: Context): Bitmap? {
            val path = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("coverPath", null)
                ?: return null
            if (!java.io.File(path).isFile) return null
            // Small enough for a widget (RemoteViews carry the bitmap across processes).
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outHeight / (sample * 2) >= 360) sample *= 2
            return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
        }

        private fun render(context: Context, layout: Int, cover: Bitmap?): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val bookId = prefs.getString("bookId", null)
            val views = RemoteViews(context.packageName, layout)
            val tall = layout == R.layout.widget_continue_reading

            val open = if (bookId != null) {
                Intent(Intent.ACTION_VIEW, Uri.parse("marginalia://app/read/$bookId"))
            } else {
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            }.setClass(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(
                android.R.id.background,
                PendingIntent.getActivity(
                    context,
                    0,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

            if (bookId == null) {
                views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_empty))
                views.setViewVisibility(R.id.widget_progress_row, View.GONE)
                views.setViewVisibility(R.id.widget_author, View.GONE)
                if (tall) views.setViewVisibility(R.id.widget_status_row, View.GONE)
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
                return views
            }

            if (tall) {
                val status = statusLine(
                    today = java.time.LocalDate.now(),
                    day = prefs.getString("day", null)?.let { runCatching { java.time.LocalDate.parse(it) }.getOrNull() },
                    todaySeconds = prefs.getInt("todaySeconds", 0),
                    streak = prefs.getInt("streak", 0),
                    goalMinutes = prefs.getInt("goalMinutes", 0),
                )
                views.setTextViewText(R.id.widget_status, status?.text.orEmpty())
                views.setViewVisibility(R.id.widget_status_row, if (status == null) View.GONE else View.VISIBLE)
                views.setViewVisibility(R.id.widget_status_icon, if (status?.streak == true) View.VISIBLE else View.GONE)
            }

            val progress = (prefs.getFloat("progress", 0f) * 100).toInt().coerceIn(0, 100)
            views.setTextViewText(R.id.widget_title, prefs.getString("title", ""))
            views.setViewVisibility(R.id.widget_progress_row, View.VISIBLE)
            views.setProgressBar(R.id.widget_progress, 100, progress, false)
            views.setTextViewText(R.id.widget_percent, "$progress%")
            val author = prefs.getString("author", null)
            views.setTextViewText(R.id.widget_author, author.orEmpty())
            views.setViewVisibility(R.id.widget_author, if (author.isNullOrBlank()) View.GONE else View.VISIBLE)
            if (cover != null) {
                views.setImageViewBitmap(R.id.widget_cover, cover)
            } else {
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
            }
            return views
        }
    }
}
