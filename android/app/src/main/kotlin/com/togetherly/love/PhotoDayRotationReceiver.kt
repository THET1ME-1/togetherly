package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONArray

class PhotoDayRotationReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.d("PhotoDayRotation", "Received action: $action")

        // После перезагрузки — восстанавливаем таймерный алarm и выходим.
        if (action == Intent.ACTION_BOOT_COMPLETED) {
            PhotoDayWidgetProvider.scheduleRotationAlarm(context)
            return
        }

        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val manager = AppWidgetManager.getInstance(context)
        val widgetIds = (
            manager.getAppWidgetIds(ComponentName(context, PhotoDayWidgetProvider::class.java)).toList() +
            manager.getAppWidgetIds(ComponentName(context, SelfPhotoWidgetProvider::class.java)).toList() +
            manager.getAppWidgetIds(ComponentName(context, PartnerPhotoWidgetProvider::class.java)).toList()
        ).distinct().toIntArray()

        if (widgetIds.isEmpty()) return

        val editor = prefs.edit()
        val rotatedIds = mutableListOf<Int>()

        for (widgetId in widgetIds) {
            val pathsStr = prefs.getString("photo_day_widget_${widgetId}_paths", null)
            if (pathsStr.isNullOrEmpty()) continue

            val paths = try { JSONArray(pathsStr) } catch (e: Exception) { null }
            if (paths == null || paths.length() <= 1) continue

            val rotationType = prefs.getString("photo_day_widget_${widgetId}_rotation_type", "unlock")
            val rotationInterval = prefs.getInt("photo_day_widget_${widgetId}_rotation_interval", 60)
            val lastUpdate = prefs.getLong("photo_day_widget_${widgetId}_last_update", 0L)
            val now = System.currentTimeMillis()

            val shouldRotate = when {
                action == Intent.ACTION_USER_PRESENT && rotationType == "unlock" -> true
                action == ACTION_ROTATE_TIMER && rotationType == "time" ->
                    now - lastUpdate >= rotationInterval * 60 * 1000L - 60_000L
                // Fallback for devices (e.g. Xiaomi/MIUI) where ACTION_USER_PRESENT
                // is blocked for manifest-declared receivers: rotate "unlock" widgets
                // via the 15-min alarm so the photo still changes periodically.
                action == ACTION_ROTATE_TIMER && rotationType == "unlock" ->
                    now - lastUpdate >= UNLOCK_FALLBACK_INTERVAL_MS
                action == Intent.ACTION_USER_PRESENT && rotationType == "time" ->
                    now - lastUpdate >= rotationInterval * 60 * 1000L
                else -> false
            }

            if (shouldRotate) {
                var currentIndex = prefs.getInt("photo_day_widget_${widgetId}_current_index", 0)
                currentIndex = (currentIndex + 1) % paths.length()
                editor.putInt("photo_day_widget_${widgetId}_current_index", currentIndex)
                editor.putLong("photo_day_widget_${widgetId}_last_update", now)
                editor.putString("photo_day_widget_${widgetId}_path", paths.optString(currentIndex, ""))
                rotatedIds.add(widgetId)
            }
        }

        if (rotatedIds.isNotEmpty()) {
            editor.apply()
            // Читаем обновлённые prefs и рисуем виджеты напрямую.
            // Нельзя sendBroadcast(ACTION_APPWIDGET_UPDATE) — это защищённый системный бродкаст.
            val updatedPrefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
            for (widgetId in rotatedIds) {
                manager.updateAppWidget(
                    widgetId,
                    PhotoDayWidgetProvider.buildViews(context, widgetId, updatedPrefs),
                )
            }
        }
    }

    companion object {
        const val ACTION_ROTATE_TIMER = "com.togetherly.love.ACTION_ROTATE_TIMER"

        /** Minimum interval between alarm-triggered rotations for "unlock" widgets.
         *  On devices where ACTION_USER_PRESENT is blocked (e.g. Xiaomi/MIUI),
         *  the photo will still change at most once per this interval. */
        private const val UNLOCK_FALLBACK_INTERVAL_MS = 15 * 60 * 1000L // 15 minutes
    }
}
