package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Shader
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import java.util.Calendar

/**
 * Виджет «Огонёк пары» — сколько дней подряд пара заходила в приложение.
 *
 * Данные пишет Flutter (HomeWidgetService.syncStreak) в HomeWidgetPreferences:
 *   streak_days       — последний известный счётчик серии
 *   streak_last_date  — дата последнего захода "YYYY-MM-DD" (локальная)
 *   streak_record     — рекорд серии
 *
 * Актуальность серии («горит» или «потухла») провайдер вычисляет сам по дате
 * на каждом onUpdate, поэтому виджет сам сбрасывается в 0 без открытия приложения.
 */
class StreakWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val storedDays = widgetData.getString("streak_days", "0")?.toIntOrNull() ?: 0
        val record = widgetData.getString("streak_record", "0")?.toIntOrNull() ?: 0
        val lastDate = widgetData.getString("streak_last_date", "") ?: ""

        val today = localDateStr(0)
        val yesterday = localDateStr(-1)
        // Серия «жива», если кто-то заходил сегодня или вчера (ещё можно продолжить).
        val alive = lastDate.isNotEmpty() && (lastDate == today || lastDate == yesterday)
        val days = if (alive) storedDays else 0

        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.streak_widget).apply {
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context, MainActivity::class.java, Uri.parse("loveapp://home")
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                // Фон: тёплый, когда горит; «потухший», когда серия прервалась.
                setInt(
                    R.id.widget_root, "setBackgroundResource",
                    if (alive && days > 0) R.drawable.streak_widget_bg
                    else R.drawable.streak_widget_bg_cold
                )

                // Огонёк + бледный водяной знак справа
                val warm = alive && days > 0
                setImageViewBitmap(R.id.streak_flame, drawFlame(200, warm))
                setImageViewBitmap(R.id.streak_bg_flame, drawFlame(360, warm))

                setTextViewText(R.id.streak_number, days.toString())
                setTextViewText(R.id.streak_label, "${pluralDays(days)} подряд")

                val sub: String = when {
                    !warm -> "Зайдите вдвоём сегодня"
                    record > days -> "Рекорд: $record ${pluralDays(record)}"
                    days >= 7 -> "Так держать! 🔥"
                    else -> "Заходите каждый день"
                }
                setTextViewText(R.id.streak_sub, sub)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    // ─── Дата ────────────────────────────────────────────────────────────────

    private fun localDateStr(dayOffset: Int): String {
        val c = Calendar.getInstance()
        c.add(Calendar.DAY_OF_YEAR, dayOffset)
        val y = c.get(Calendar.YEAR)
        val m = c.get(Calendar.MONTH) + 1
        val d = c.get(Calendar.DAY_OF_MONTH)
        return "%04d-%02d-%02d".format(y, m, d)
    }

    // ─── Склонение «день / дня / дней» ───────────────────────────────────────

    private fun pluralDays(n: Int): String {
        val n100 = n % 100
        val n10 = n % 10
        return when {
            n10 == 1 && n100 != 11 -> "день"
            n10 in 2..4 && (n100 < 10 || n100 >= 20) -> "дня"
            else -> "дней"
        }
    }

    // ─── Рисование огонька ───────────────────────────────────────────────────

    private fun drawFlame(size: Int, warm: Boolean): Bitmap {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val w = size.toFloat()
        val h = size.toFloat()

        // Цвета: тёплый огонь vs потухший пепел
        val tip: Int; val mid: Int; val base: Int
        val coreTop: Int; val coreBottom: Int; val glowColor: Int
        if (warm) {
            tip = Color.parseColor("#FFE08A")
            mid = Color.parseColor("#FF8A3D")
            base = Color.parseColor("#FF3D6E")
            coreTop = Color.parseColor("#FFFFFF")
            coreBottom = Color.parseColor("#FFE59A")
            glowColor = Color.parseColor("#FFB347")
        } else {
            tip = Color.parseColor("#D7DEE8")
            mid = Color.parseColor("#A6B2C2")
            base = Color.parseColor("#7C8799")
            coreTop = Color.parseColor("#F0F3F7")
            coreBottom = Color.parseColor("#C9D2DE")
            glowColor = Color.parseColor("#AEB9C7")
        }

        // Мягкое свечение под огоньком
        val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                w * 0.5f, h * 0.62f, w * 0.52f,
                intArrayOf(withAlpha(glowColor, if (warm) 120 else 60), withAlpha(glowColor, 0)),
                null, Shader.TileMode.CLAMP
            )
        }
        canvas.drawCircle(w * 0.5f, h * 0.62f, w * 0.52f, glow)

        // Внешнее пламя
        val outer = flamePath(w, h, 1.0f)
        val outerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, h, 0f, 0f,
                intArrayOf(base, mid, tip), floatArrayOf(0f, 0.55f, 1f),
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawPath(outer, outerPaint)

        // Внутреннее ядро (светлое)
        val inner = flamePath(w, h, 0.52f)
        val innerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, h * 0.95f, 0f, h * 0.25f,
                intArrayOf(coreBottom, coreTop), null,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawPath(inner, innerPaint)

        return bmp
    }

    /** Контур пламени в коробке [w]×[h], масштабируется вокруг низа-центра. */
    private fun flamePath(w: Float, h: Float, scale: Float): Path {
        val cx = w / 2f
        val bottom = h * 0.97f
        val path = Path().apply {
            moveTo(cx, h * 0.05f)
            cubicTo(w * 0.70f, h * 0.21f, w * 0.82f, h * 0.41f, w * 0.78f, h * 0.61f)
            cubicTo(w * 0.75f, h * 0.81f, w * 0.63f, bottom, cx, bottom)
            cubicTo(w * 0.37f, bottom, w * 0.25f, h * 0.81f, w * 0.22f, h * 0.60f)
            cubicTo(w * 0.20f, h * 0.43f, w * 0.35f, h * 0.32f, w * 0.41f, h * 0.19f)
            cubicTo(w * 0.45f, h * 0.11f, w * 0.47f, h * 0.08f, cx, h * 0.05f)
            close()
        }
        if (scale != 1.0f) {
            val m = Matrix()
            m.postScale(scale, scale, cx, bottom)
            path.transform(m)
        }
        return path
    }

    private fun withAlpha(color: Int, alpha: Int): Int =
        (alpha shl 24) or (color and 0x00FFFFFF)
}
