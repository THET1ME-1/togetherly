package com.togetherly.love

import android.content.Context

object WidgetGroupHelper {
    /**
     * Returns the groupId bound to this widget instance.
     * If not yet bound:
     *   1. Checks {widgetType}_next_bind_group (set by Flutter before pinning)
     *   2. Falls back to {dataType}_latest_group (last synced group)
     * Saves the binding for future calls.
     * [dataType] defaults to [widgetType] but petal_timer uses dataType="timer".
     */
    fun getOrBind(context: Context, widgetType: String, widgetId: Int, dataType: String = widgetType): String {
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val bindKey = "widget_${widgetType}_${widgetId}_group"
        val stored = prefs.getString(bindKey, null)
        if (!stored.isNullOrEmpty()) return stored

        val pending = prefs.getString("${widgetType}_next_bind_group", null)?.takeIf { it.isNotEmpty() }
        if (pending != null) {
            prefs.edit().putString(bindKey, pending).remove("${widgetType}_next_bind_group").apply()
            return pending
        }

        val latest = prefs.getString("${dataType}_latest_group", null)?.takeIf { it.isNotEmpty() }
        if (latest != null) {
            prefs.edit().putString(bindKey, latest).apply()
            return latest
        }
        return ""
    }

    fun clearBindings(context: Context, widgetType: String, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        prefs.edit().also { e -> appWidgetIds.forEach { e.remove("widget_${widgetType}_${it}_group") } }.apply()
    }
}
