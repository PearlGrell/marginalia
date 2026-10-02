package app.marginalia

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews

/**
 * "Continue reading" on the home screen: the book read last, with its cover and progress.
 * Tapping it opens the book. The app keeps it current through [update] (see DeviceChannel's
 * `updateWidget`), so it never wakes the app itself.
 */
class ContinueReadingWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = render(context)
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    companion object {
        private const val PREFS = "marginalia_widget"

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
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ContinueReadingWidget::class.java))
            if (ids.isNotEmpty()) {
                val views = render(context)
                ids.forEach { manager.updateAppWidget(it, views) }
            }
        }

        private fun render(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val bookId = prefs.getString("bookId", null)
            val views = RemoteViews(context.packageName, R.layout.widget_continue_reading)

            val open = if (bookId != null) {
                Intent(Intent.ACTION_VIEW, Uri.parse("marginalia://app/read/$bookId"))
            } else {
                Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            }.setClass(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(
                    context,
                    0,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )

            if (bookId == null) {
                views.setTextViewText(R.id.widget_title, context.getString(R.string.widget_empty))
                views.setViewVisibility(R.id.widget_author, View.GONE)
                views.setViewVisibility(R.id.widget_progress_row, View.GONE)
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
                return views
            }

            val progress = (prefs.getFloat("progress", 0f) * 100).toInt().coerceIn(0, 100)
            views.setTextViewText(R.id.widget_title, prefs.getString("title", ""))
            val author = prefs.getString("author", null)
            views.setTextViewText(R.id.widget_author, author.orEmpty())
            views.setViewVisibility(R.id.widget_author, if (author.isNullOrBlank()) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.widget_progress_row, View.VISIBLE)
            views.setProgressBar(R.id.widget_progress, 100, progress, false)
            views.setTextViewText(R.id.widget_percent, "$progress%")

            val cover = prefs.getString("coverPath", null)?.let { path ->
                // Small enough for a widget (RemoteViews carry the bitmap across processes).
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, bounds)
                var sample = 1
                while (bounds.outHeight / (sample * 2) >= 260) sample *= 2
                BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            }
            if (cover != null) {
                views.setImageViewBitmap(R.id.widget_cover, cover)
            } else {
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
            }
            return views
        }
    }
}
