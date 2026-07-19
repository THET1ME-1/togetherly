package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Виджет «Фото-сетка» — отображает 1, 2 или 4 фото из Memory Lane.
 * Количество задаётся ключом photo_grid_count (1/2/4),
 * пути к файлам — photo_grid_0 … photo_grid_3.
 */
class PhotoGridWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.photo_grid_widget).apply {

                // Клик открывает Memory Lane
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("loveapp://memory_lane")
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                // Per-widget ключи с fallback на старые глобальные (миграция)
                val count = (widgetData.getInt("photo_grid_${widgetId}_count", -1)
                    .takeIf { it >= 0 } ?: widgetData.getInt("photo_grid_count", 1)).let {
                    when {
                        it >= 4 -> 4
                        it >= 2 -> 2
                        else    -> 1
                    }
                }

                // Скрываем все layouts, затем показываем нужный
                setViewVisibility(R.id.layout_1_photo, View.GONE)
                setViewVisibility(R.id.layout_2_photos, View.GONE)
                setViewVisibility(R.id.layout_4_photos, View.GONE)

                when (count) {
                    1 -> {
                        setViewVisibility(R.id.layout_1_photo, View.VISIBLE)
                        loadSlot(this, widgetData, widgetId, 0, R.id.photo_0, R.id.placeholder_0, 400)
                    }
                    2 -> {
                        setViewVisibility(R.id.layout_2_photos, View.VISIBLE)
                        loadSlot(this, widgetData, widgetId, 0, R.id.photo_2_0, R.id.placeholder_2_0, 300)
                        loadSlot(this, widgetData, widgetId, 1, R.id.photo_2_1, R.id.placeholder_2_1, 300)
                    }
                    4 -> {
                        setViewVisibility(R.id.layout_4_photos, View.VISIBLE)
                        loadSlot(this, widgetData, widgetId, 0, R.id.photo_4_0, R.id.placeholder_4_0, 200)
                        loadSlot(this, widgetData, widgetId, 1, R.id.photo_4_1, R.id.placeholder_4_1, 200)
                        loadSlot(this, widgetData, widgetId, 2, R.id.photo_4_2, R.id.placeholder_4_2, 200)
                        loadSlot(this, widgetData, widgetId, 3, R.id.photo_4_3, R.id.placeholder_4_3, 200)
                    }
                }
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", android.content.Context.MODE_PRIVATE)
        val editor = prefs.edit()
        appWidgetIds.forEach { widgetId ->
            editor.remove("photo_grid_${widgetId}_count")
            for (i in 0..3) {
                editor.remove("photo_grid_${widgetId}_$i")
            }
        }
        editor.apply()
    }

    private fun loadSlot(
        views: RemoteViews,
        widgetData: SharedPreferences,
        widgetId: Int,
        index: Int,
        imageViewId: Int,
        placeholderId: Int,
        maxSizePx: Int,
    ) {
        // Per-widget ключ с fallback на старый глобальный
        val path = widgetData.getString("photo_grid_${widgetId}_$index", null)
            ?: widgetData.getString("photo_grid_$index", null)
        val bitmap = loadScaledBitmap(path, maxSizePx)
        if (bitmap != null) {
            views.setImageViewBitmap(imageViewId, bitmap)
            views.setViewVisibility(imageViewId, View.VISIBLE)
            views.setViewVisibility(placeholderId, View.GONE)
        } else {
            views.setViewVisibility(imageViewId, View.GONE)
            views.setViewVisibility(placeholderId, View.VISIBLE)
        }
    }

    private fun loadScaledBitmap(path: String?, maxSizePx: Int): Bitmap? {
        if (path.isNullOrEmpty()) return null
        val file = java.io.File(path)
        if (!file.exists()) return null

        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, opts)
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null

        var sampleSize = 1
        var w = opts.outWidth
        var h = opts.outHeight
        while (w / 2 >= maxSizePx || h / 2 >= maxSizePx) {
            sampleSize *= 2
            w /= 2
            h /= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        return try {
            BitmapFactory.decodeFile(path, decodeOpts)
        } catch (e: OutOfMemoryError) {
            null
        }
    }
}
