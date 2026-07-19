package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Виджет «Счётчик дней вместе» — крупное число дней,
 * имена пары, эмодзи отношений, дата начала.
 */
class DaysCounterWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val g = WidgetGroupHelper.getOrBind(context, "days_counter", widgetId)
            val views = RemoteViews(context.packageName, R.layout.days_counter_widget).apply {

                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("loveapp://home")
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)

                // ── Данные ──
                val daysStr = if (g.isEmpty()) "0" else widgetData.getString("days_${g}_count", null)
                    .takeIf { !it.isNullOrEmpty() } ?: "0"
                val totalDays = daysStr.toIntOrNull() ?: 0

                val startDate = if (g.isEmpty()) "" else widgetData.getString("days_${g}_start_date", null)
                    .takeIf { !it.isNullOrEmpty() } ?: ""

                // ── Гендер и выбор картинки пары ──
                val myGender = if (g.isEmpty()) "male" else widgetData.getString("days_${g}_my_gender", "male") ?: "male"
                val partnerGender = if (g.isEmpty()) "female" else widgetData.getString("days_${g}_partner_gender", "female") ?: "female"

                val coupleResName = when {
                    myGender == "female" && partnerGender == "female" -> "widget_couple_ff"
                    myGender == "male" && partnerGender == "male" -> "widget_couple_mm"
                    else -> "widget_couple_mf"
                }

                val coupleResId = context.resources.getIdentifier(coupleResName, "drawable", context.packageName)
                if (coupleResId != 0) {
                    setImageViewResource(R.id.couple_image, coupleResId)
                }
                // User is always on the left; flip mf image when user=female, partner=male
                setFloat(R.id.couple_image, "setScaleX", if (myGender == "female" && partnerGender == "male") -1f else 1f)

                // ── Свои фото пары вместо рисунка (фича days_widget_photos) ──
                val usePhotos = !g.isEmpty() &&
                    widgetData.getString("days_${g}_use_photos", "0") == "1"
                val myAvatarPath = if (g.isEmpty()) null else widgetData.getString("days_${g}_my_avatar_path", null)
                val partnerAvatarPath = if (g.isEmpty()) null else widgetData.getString("days_${g}_partner_avatar_path", null)

                val myAvatar = if (usePhotos) circularBitmap(
                    PhotoDayWidgetProvider.loadScaledBitmapStatic(myAvatarPath, 160)
                ) else null
                val partnerAvatar = if (usePhotos) circularBitmap(
                    PhotoDayWidgetProvider.loadScaledBitmapStatic(partnerAvatarPath, 160)
                ) else null

                if (myAvatar != null && partnerAvatar != null) {
                    setImageViewBitmap(R.id.avatar_left, myAvatar)
                    setImageViewBitmap(R.id.avatar_right, partnerAvatar)
                    setViewVisibility(R.id.avatar_row, View.VISIBLE)
                    setViewVisibility(R.id.couple_image, View.GONE)
                } else {
                    setViewVisibility(R.id.avatar_row, View.GONE)
                    setViewVisibility(R.id.couple_image, View.VISIBLE)
                }

                // ── Расчёт лет ──
                val years = totalDays / 365
                val yearsText = when {
                    years % 10 == 1 && years % 100 != 11 -> "$years год уже ❤️"
                    years % 10 in 2..4 && (years % 100 < 10 || years % 100 >= 20) -> "$years года уже ❤️"
                    else -> "$years лет уже ❤️"
                }
                setTextViewText(R.id.years_label, yearsText)

                // ── Дни и дата ──
                setTextViewText(R.id.days_number, totalDays.toString())
                setTextViewText(R.id.days_label_text, "дней") // Или "Days" как в фото
                setTextViewText(R.id.start_date, startDate)

                // ── Совместимость (скрытые поля) ──
                setTextViewText(R.id.days_label, "")
                setTextViewText(R.id.couple_names, "")
                setTextViewText(R.id.love_emoji, "")
            }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        WidgetGroupHelper.clearBindings(context, "days_counter", appWidgetIds)
    }

    /**
     * Кадрирует bitmap в круг (центр-кроп до квадрата + круглая маска).
     * Возвращает ARGB_8888 с прозрачными углами, готовый для setImageViewBitmap.
     */
    private fun circularBitmap(src: Bitmap?): Bitmap? {
        if (src == null) return null
        val size = minOf(src.width, src.height)
        if (size <= 0) return null
        val square = try {
            Bitmap.createBitmap(src, (src.width - size) / 2, (src.height - size) / 2, size, size)
        } catch (e: Exception) {
            return null
        }
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint().apply {
            isAntiAlias = true
            shader = BitmapShader(square, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        val r = size / 2f
        canvas.drawCircle(r, r, r, paint)
        return output
    }
}
