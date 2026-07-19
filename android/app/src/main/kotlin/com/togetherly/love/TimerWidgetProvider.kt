package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.PI

class TimerWidgetProvider : HomeWidgetProvider() {

    private enum class Theme {
        ROMANTIC,   // married, engaged, in_relationship, dating
        NEUTRAL,    // всё остальное (друзья, кастомные статусы и т.д.)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val g = WidgetGroupHelper.getOrBind(context, "timer", widgetId)
            val views = RemoteViews(context.packageName, R.layout.timer_widget).apply {
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("loveapp://home")
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                val title = if (g.isEmpty()) "—" else widgetData.getString("timer_${g}_title", null)
                    .takeIf { !it.isNullOrEmpty() } ?: "Таймер"
                val daysStr = if (g.isEmpty()) "0" else widgetData.getString("timer_${g}_days", null)
                    .takeIf { !it.isNullOrEmpty() } ?: "0"
                val days = abs(daysStr.toIntOrNull() ?: 0)
                val isCountdown = if (g.isEmpty()) false else widgetData.getString("timer_${g}_is_countdown", "0") == "1"
                val date = if (g.isEmpty()) "" else widgetData.getString("timer_${g}_date", null)
                    .takeIf { !it.isNullOrEmpty() } ?: ""
                val isRomantic = if (g.isEmpty()) true else widgetData.getString("timer_${g}_is_romantic", "1") != "0"

                val theme = if (isRomantic) Theme.ROMANTIC else Theme.NEUTRAL
                val colors = themeColors(theme)

                // Фон
                setInt(R.id.widget_root, "setBackgroundResource",
                    if (theme == Theme.ROMANTIC) R.drawable.timer_widget_bg
                    else R.drawable.timer_widget_bg_neutral
                )

                // Тексты
                val daysLabel = if (isCountdown) "дней осталось" else "дней вместе"
                setTextViewText(R.id.timer_title, title)
                setTextViewText(R.id.timer_days_number, days.toString())
                setTextViewText(R.id.timer_days_label, daysLabel)
                setTextViewText(R.id.timer_date, date)

                // Цвета текста
                setTextColor(R.id.timer_title, Color.parseColor(colors.title))
                setTextColor(R.id.timer_days_number, Color.parseColor(colors.number))
                setTextColor(R.id.timer_days_label, Color.parseColor(colors.label))
                setTextColor(R.id.timer_date, Color.parseColor(colors.date))

                // Иконка рядом с заголовком
                setImageViewBitmap(R.id.timer_heart_icon,
                    if (theme == Theme.ROMANTIC)
                        drawHeart(28, colors.iconFrom, colors.iconTo)
                    else
                        drawStar(28, colors.iconFrom, colors.iconTo)
                )

                // Декоративная большая иконка (фон)
                setImageViewBitmap(R.id.timer_bg_heart,
                    if (theme == Theme.ROMANTIC)
                        drawHeart(180, colors.iconFrom, colors.iconTo)
                    else
                        drawStar(180, colors.iconFrom, colors.iconTo)
                )

            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    // ─── Палитра ────────────────────────────────────────────────────────

    private data class Colors(
        val title: String, val number: String,
        val label: String, val date: String,
        val iconFrom: String, val iconTo: String,
    )

    private fun themeColors(theme: Theme) = when (theme) {
        Theme.ROMANTIC -> Colors(
            title = "#C084B8", number = "#B5488A",
            label = "#9B7AA8", date = "#C4A8D4",
            iconFrom = "#D4609A", iconTo = "#E891C8",
        )
        Theme.NEUTRAL -> Colors(
            title = "#9C7A3A", number = "#C2760A",
            label = "#A8936A", date = "#C4B080",
            iconFrom = "#E8A020", iconTo = "#F5C842",
        )
    }

    // ─── Рисование сердца ───────────────────────────────────────────────

    private fun drawHeart(size: Int, fromHex: String, toHex: String): Bitmap {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val w = size.toFloat(); val h = size.toFloat()
        val path = Path().apply {
            moveTo(w * 0.5f, h * 0.27f)
            cubicTo(w * 0.5f, h * 0.245f, w * 0.45f, h * 0.14f, w * 0.25f, h * 0.14f)
            cubicTo(0f, h * 0.14f, 0f, h * 0.46f, 0f, h * 0.46f)
            cubicTo(0f, h * 0.71f, w * 0.25f, h * 0.84f, w * 0.5f, h)
            cubicTo(w * 0.75f, h * 0.84f, w, h * 0.71f, w, h * 0.46f)
            cubicTo(w, h * 0.46f, w, h * 0.14f, w * 0.75f, h * 0.14f)
            cubicTo(w * 0.6f, h * 0.14f, w * 0.5f, h * 0.245f, w * 0.5f, h * 0.27f)
            close()
        }
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(0f, 0f, w, h,
                Color.parseColor(fromHex), Color.parseColor(toHex), Shader.TileMode.CLAMP)
            style = Paint.Style.FILL
        }
        canvas.drawPath(path, paint)
        return bmp
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        WidgetGroupHelper.clearBindings(context, "timer", appWidgetIds)
    }

    // ─── Рисование звезды ───────────────────────────────────────────────

    private fun drawStar(size: Int, fromHex: String, toHex: String): Bitmap {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val cx = size / 2f; val cy = size / 2f
        val outerR = size * 0.46f; val innerR = size * 0.19f
        val path = Path()
        val points = 5
        for (i in 0 until points * 2) {
            val angle = (i * PI / points - PI / 2).toFloat()
            val r = if (i % 2 == 0) outerR else innerR
            val x = cx + r * cos(angle)
            val y = cy + r * sin(angle)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(0f, 0f, size.toFloat(), size.toFloat(),
                Color.parseColor(fromHex), Color.parseColor(toHex), Shader.TileMode.CLAMP)
            style = Paint.Style.FILL
        }
        canvas.drawPath(path, paint)
        return bmp
    }
}
