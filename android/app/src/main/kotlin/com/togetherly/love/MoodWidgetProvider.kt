package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import kotlin.math.PI
import kotlin.math.sin

class MoodWidgetProvider : HomeWidgetProvider() {

    companion object {
        private const val TAG = "MoodWidgetProvider"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val g = WidgetGroupHelper.getOrBind(context, "mood", widgetId)
            val views = RemoteViews(context.packageName, R.layout.mood_widget)
            try {
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("loveapp://mood")
                )
                views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)
                populateMoodPreview(views, widgetData, g)
            } catch (e: Exception) {
                Log.e(TAG, "Error updating widget $widgetId", e)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        super.onDeleted(context, appWidgetIds)
        WidgetGroupHelper.clearBindings(context, "mood", appWidgetIds)
    }

    private fun populateMoodPreview(
        views: RemoteViews,
        widgetData: SharedPreferences,
        g: String,
    ) {
        for (i in 0..1) {
            try {
                val scoreKey = if (g.isEmpty()) "user_${i}_score" else "mood_${g}_user_${i}_score"
                val colorKey = if (g.isEmpty()) "user_${i}_color" else "mood_${g}_user_${i}_color"
                val labelKey = if (g.isEmpty()) "user_${i}_label" else "mood_${g}_user_${i}_label"
                val score = widgetData.getInt(scoreKey, 0).coerceIn(0, 5)
                val colorHex = widgetData.getString(colorKey, "") ?: ""
                val label = widgetData.getString(labelKey, "")
                    ?: widgetData.getString("user_${i}_label", "") ?: ""
                val heartId = if (i == 0) R.id.heart_2_0 else R.id.heart_2_1
                val labelId = if (i == 0) R.id.label_2_0 else R.id.label_2_1
                val waterColor = parseColor(colorHex)
                val t = score / 5.0
                val easedFill = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
                val heartBitmap = createWaterHeartBitmap(88, easedFill, waterColor)
                views.setImageViewBitmap(heartId, heartBitmap)
                views.setTextViewText(labelId, label)

                // Avatar
                val avatarId = if (i == 0) R.id.avatar_0 else R.id.avatar_1
                val avatarPath = widgetData.getString("user_${i}_avatar_path", "") ?: ""
                val avatarBitmap = loadScaledBitmap(avatarPath, 80)
                if (avatarBitmap != null) {
                    views.setImageViewBitmap(avatarId, getCircularBitmap(avatarBitmap))
                    views.setViewVisibility(avatarId, View.VISIBLE)
                } else {
                    views.setViewVisibility(avatarId, View.GONE)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error populating mood for user $i", e)
            }
        }
    }

    private fun getCircularBitmap(bitmap: Bitmap): Bitmap {
        val size = minOf(bitmap.width, bitmap.height)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint().apply { isAntiAlias = true }
        val srcRect = Rect(
            (bitmap.width - size) / 2, (bitmap.height - size) / 2,
            (bitmap.width + size) / 2, (bitmap.height + size) / 2
        )
        val dstRectF = RectF(0f, 0f, size.toFloat(), size.toFloat())
        val radius = size / 2f
        canvas.drawARGB(0, 0, 0, 0)
        canvas.drawRoundRect(dstRectF, radius, radius, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(bitmap, srcRect, dstRectF, paint)
        paint.xfermode = null
        paint.style = Paint.Style.STROKE
        paint.color = Color.WHITE
        paint.alpha = 180
        paint.strokeWidth = size * 0.06f
        canvas.drawCircle(radius, radius, radius - paint.strokeWidth / 2f, paint)
        return output
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
            sampleSize *= 2; w /= 2; h /= 2
        }
        return try {
            BitmapFactory.decodeFile(path, BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.RGB_565
            })
        } catch (e: OutOfMemoryError) { null }
    }

    private fun parseColor(hex: String): Int {
        return try {
            when {
                hex.isEmpty() -> Color.parseColor("#D1D5DB")
                hex.startsWith("#") -> Color.parseColor(hex)
                hex.startsWith("0x") -> hex.toLong(16).toInt()
                else -> Color.parseColor("#$hex")
            }
        } catch (e: Exception) {
            Color.parseColor("#D1D5DB")
        }
    }

    private fun createWaterHeartBitmap(size: Int, fillLevel: Double, waterColor: Int): Bitmap {
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)

        // Отступ 6% с каждой стороны — чтобы антиалиасинг не обрезался по краям bitmap
        val margin = size * 0.06f
        val drawScale = (size - 2f * margin) / size
        canvas.save()
        canvas.translate(margin, margin)
        canvas.scale(drawScale, drawScale)

        val heartPath = createHeartPath(size.toFloat(), size.toFloat())

        val bgPaint = Paint().apply {
            color = waterColor
            alpha = 20
            style = Paint.Style.FILL
            isAntiAlias = true
        }
        canvas.drawPath(heartPath, bgPaint)

        if (fillLevel > 0.005) {
            canvas.save()
            canvas.clipPath(heartPath)

            val waterTop = size * (1 - fillLevel).toFloat()
            val waveAmp = size * 0.03f

            val waterPath = Path()
            waterPath.moveTo(-1f, waterTop)

            val steps = 24
            for (i in 0..steps) {
                val x = size * i.toFloat() / steps
                val y = waterTop + sin(x / size * 2 * PI - PI * 0.5).toFloat() * waveAmp
                waterPath.lineTo(x, y)
            }
            waterPath.lineTo(size + 1f, size.toFloat())
            waterPath.lineTo(-1f, size.toFloat())
            waterPath.close()

            val waterPaint = Paint().apply {
                shader = LinearGradient(
                    0f, waterTop, 0f, size.toFloat(),
                    adjustAlpha(waterColor, 0.68f),
                    adjustAlpha(waterColor, 0.90f),
                    Shader.TileMode.CLAMP
                )
                style = Paint.Style.FILL
                isAntiAlias = true
            }
            canvas.drawPath(waterPath, waterPaint)

            if (fillLevel > 0.15) {
                val bubblePaint = Paint().apply {
                    color = Color.WHITE
                    alpha = 77
                    isAntiAlias = true
                }
                canvas.drawCircle(
                    size * 0.32f,
                    waterTop + size * 0.12f,
                    size * 0.06f,
                    bubblePaint
                )
            }

            canvas.restore()
        }

        val borderPaint = Paint().apply {
            color = adjustAlpha(waterColor, 0.5f)
            style = Paint.Style.STROKE
            strokeWidth = 2.0f
            strokeJoin = Paint.Join.ROUND
            isAntiAlias = true
        }
        canvas.drawPath(heartPath, borderPaint)

        canvas.restore() // restore translate+scale inset

        return output
    }

    private fun createHeartPath(width: Float, height: Float): Path {
        return Path().apply {
            moveTo(width * 0.5f, height * 0.27f)
            cubicTo(width * 0.5f, height * 0.245f, width * 0.45f, height * 0.14f, width * 0.25f, height * 0.14f)
            cubicTo(0f, height * 0.14f, 0f, height * 0.46f, 0f, height * 0.46f)
            cubicTo(0f, height * 0.71f, width * 0.25f, height * 0.84f, width * 0.5f, height)
            cubicTo(width * 0.75f, height * 0.84f, width, height * 0.71f, width, height * 0.46f)
            cubicTo(width, height * 0.46f, width, height * 0.14f, width * 0.75f, height * 0.14f)
            cubicTo(width * 0.6f, height * 0.14f, width * 0.5f, height * 0.245f, width * 0.5f, height * 0.27f)
            close()
        }
    }

    private fun adjustAlpha(color: Int, factor: Float): Int {
        val alpha = (Color.alpha(color) * factor).toInt().coerceIn(0, 255)
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color))
    }
}
