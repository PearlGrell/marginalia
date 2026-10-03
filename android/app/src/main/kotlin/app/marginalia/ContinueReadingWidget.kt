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
 * "Continue reading" on the home screen: the book read last, with its cover and progress.
 * Tapping it opens the book. It follows the wallpaper's colors on Android 12 and later, and
 * has a one-row layout for when it's one cell tall. The app keeps it current through [update]
 * (see DeviceChannel's `updateWidget`), so it never wakes the app itself.
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
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, ContinueReadingWidget::class.java)).forEach {
                manager.updateAppWidget(it, views(context, manager.getAppWidgetOptions(it)))
            }
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
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
                return views
            }

            val progress = (prefs.getFloat("progress", 0f) * 100).toInt().coerceIn(0, 100)
            views.setTextViewText(R.id.widget_title, prefs.getString("title", ""))
            views.setViewVisibility(R.id.widget_progress_row, View.VISIBLE)
            views.setProgressBar(R.id.widget_progress, 100, progress, false)
            views.setTextViewText(R.id.widget_percent, if (tall) "$progress% read" else "$progress%")
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
