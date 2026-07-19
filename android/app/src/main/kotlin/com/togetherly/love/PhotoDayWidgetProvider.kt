package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import org.json.JSONObject

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Intent
import android.os.SystemClock

/**
 * Виджет «Фото дня» — случайное фото из Memory Lane.
 * При нажатии открывается лента воспоминаний.
 */
open class PhotoDayWidgetProvider : HomeWidgetProvider() {

    protected open fun expectedKind(): String? = null

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        ensurePendingConfigsAssigned(context, widgetData, appWidgetIds)
        scheduleRotationAlarm(context)

        appWidgetIds.forEach { widgetId ->
            appWidgetManager.updateAppWidget(
                widgetId,
                buildViews(context, widgetId, widgetData),
            )
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val editor = prefs.edit()
        appWidgetIds.forEach { widgetId ->
            editor.remove(key(widgetId, "group_id"))
            editor.remove(key(widgetId, "mode"))
            editor.remove(key(widgetId, "display"))
            editor.remove(key(widgetId, "kind"))
            editor.remove(key(widgetId, "name"))
            editor.remove(key(widgetId, "path"))
            editor.remove(key(widgetId, "paths"))
            editor.remove(key(widgetId, "urls"))
            editor.remove(key(widgetId, "custom_path"))
            editor.remove(key(widgetId, "caption"))
            editor.remove(key(widgetId, "memory_id"))
            editor.remove(key(widgetId, "author"))
            editor.remove(key(widgetId, "author_uid"))
            editor.remove(key(widgetId, "viewer_uid"))
            editor.remove(key(widgetId, "viewer_name"))
            editor.remove(key(widgetId, "refresh_seed"))
            editor.remove(key(widgetId, "rotation_type"))
            editor.remove(key(widgetId, "rotation_interval"))
            editor.remove(key(widgetId, "current_index"))
            editor.remove(key(widgetId, "last_update"))
        }
        editor.apply()
    }

    private fun ensurePendingConfigsAssigned(
        context: Context,
        widgetData: SharedPreferences,
        appWidgetIds: IntArray,
    ) {
        val manager = AppWidgetManager.getInstance(context)
        val component = ComponentName(context, javaClass)
        val existingIds = manager.getAppWidgetIds(component).toSet()
        val pendingRaw = widgetData.getString(PENDING_CONFIGS_KEY, null) ?: return
        val pending = try {
            JSONArray(pendingRaw)
        } catch (_: Exception) {
            return
        }

        if (pending.length() == 0) return

        val unassignedIds = (if (appWidgetIds.isNotEmpty()) appWidgetIds.toSet() else existingIds)
            .filter { widgetData.getString(key(it, "group_id"), null).isNullOrEmpty() }
            .sorted()
            .toMutableList()
        if (unassignedIds.isEmpty()) return

        val remaining = JSONArray()
        val editor = widgetData.edit()
        val requiredKind = expectedKind()
        for (i in 0 until pending.length()) {
            val item = pending.optJSONObject(i) ?: continue
            val itemKind = item.optString("kind", "")
            val kindMatches = requiredKind == null || itemKind.isEmpty() || itemKind == requiredKind
            if (unassignedIds.isNotEmpty() && kindMatches) {
                val widgetId = unassignedIds.removeAt(0)
                assignConfig(editor, widgetId, item)
            } else {
                remaining.put(item)
            }
        }

        editor.putString(PENDING_CONFIGS_KEY, remaining.toString())
        editor.apply()
        Log.d("PhotoDayWidget", "Assigned pending configs to widgets")
    }

    private fun assignConfig(editor: SharedPreferences.Editor, widgetId: Int, item: JSONObject) {
        editor.putString(key(widgetId, "group_id"), item.optString("groupId", ""))
        editor.putString(key(widgetId, "mode"), item.optString("mode", "random"))
        editor.putString(key(widgetId, "display"), item.optString("display", "partner"))
        editor.putString(key(widgetId, "kind"), item.optString("kind", if (item.optString("display", "mine") == "partner") "partner" else "self"))
        editor.putString(key(widgetId, "path"), item.optString("path", ""))
        editor.putString(key(widgetId, "caption"), item.optString("caption", ""))
        editor.putString(key(widgetId, "memory_id"), item.optString("memoryId", ""))
        editor.putString(key(widgetId, "author"), item.optString("authorName", ""))
        editor.putString(key(widgetId, "author_uid"), item.optString("authorUid", ""))
        editor.putString(key(widgetId, "viewer_uid"), item.optString("viewerUid", ""))
        editor.putString(key(widgetId, "viewer_name"), item.optString("viewerName", ""))
        editor.putInt(key(widgetId, "refresh_seed"), item.optInt("refreshSeed", 0))
    }

    companion object {
        private const val PENDING_CONFIGS_KEY = "photo_day_pending_configs"

        fun key(widgetId: Int, suffix: String): String = "photo_day_widget_${widgetId}_$suffix"

        fun buildViews(
            context: Context,
            widgetId: Int,
            widgetData: SharedPreferences,
        ): RemoteViews = RemoteViews(context.packageName, R.layout.photo_day_widget).apply {
            val memoryId = widgetData.getString("photo_day_widget_${widgetId}_memory_id", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""

            val uri = if (memoryId.isNotEmpty())
                "loveapp://memory_lane?id=$memoryId"
            else
                "loveapp://memory_lane"

            val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse(uri),
            )
            setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            val photoPath = widgetData.getString("photo_day_widget_${widgetId}_path", null)
                .takeIf { !it.isNullOrEmpty() }

            val bitmap = loadScaledBitmapStatic(photoPath, 400)
            if (bitmap != null) {
                setImageViewBitmap(R.id.photo_image, bitmap)
                setViewVisibility(R.id.photo_image, View.VISIBLE)
                setViewVisibility(R.id.photo_placeholder, View.GONE)
            } else {
                setViewVisibility(R.id.photo_image, View.GONE)
                setViewVisibility(R.id.photo_placeholder, View.VISIBLE)
            }
            setViewVisibility(R.id.photo_author, View.GONE)
        }

        fun loadScaledBitmapStatic(path: String?, maxSizePx: Int): Bitmap? {
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

        // Bump this whenever the alarm setup changes (type, interval, etc.).
        // Causes an immediate reschedule on the first call after an app update,
        // even if the 30-minute gate would otherwise prevent it.
        private const val ALARM_VERSION = 2

        fun scheduleRotationAlarm(context: Context) {
            val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
            val lastScheduled = prefs.getLong("rotation_alarm_last_scheduled", 0L)
            val alarmVersion = prefs.getInt("rotation_alarm_version", 0)
            val now = System.currentTimeMillis()

            // Reschedule at most every 30 minutes to prevent frequent syncs from
            // constantly pushing the first-fire time into the future.
            // Exception: if ALARM_VERSION changed (e.g. type upgrade), reschedule immediately.
            if (alarmVersion >= ALARM_VERSION && now - lastScheduled < 30 * 60 * 1000L) return

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, PhotoDayRotationReceiver::class.java).apply {
                action = PhotoDayRotationReceiver.ACTION_ROTATE_TIMER
            }

            // Cancel existing alarm before rescheduling so we can change the type
            // from the old ELAPSED_REALTIME (doesn't wake device) to ELAPSED_REALTIME_WAKEUP.
            val cancelFlags = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_NO_CREATE
            }
            val existing = PendingIntent.getBroadcast(context, 0, intent, cancelFlags)
            if (existing != null) {
                alarmManager.cancel(existing)
                existing.cancel()
            }

            val scheduleFlags = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getBroadcast(context, 0, intent, scheduleFlags)

            // 15-minute interval. ELAPSED_REALTIME_WAKEUP fires even in Doze/sleep,
            // so the photo rotates in the background without the app running.
            val interval = 15 * 60 * 1000L
            alarmManager.setInexactRepeating(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + interval,
                interval,
                pendingIntent
            )

            prefs.edit()
                .putLong("rotation_alarm_last_scheduled", now)
                .putInt("rotation_alarm_version", ALARM_VERSION)
                .apply()
            Log.d("PhotoDayWidget", "Rotation alarm scheduled with WAKEUP flag (15 min interval, v$ALARM_VERSION)")
        }
    }

}
