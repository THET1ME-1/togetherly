package com.togetherly.love

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
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

class LoveWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = try {
                buildViews(context, widgetData)
            } catch (e: Exception) {
                Log.e("LoveWidgetProvider", "onUpdate error", e)
                return@forEach
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun buildViews(context: Context, widgetData: SharedPreferences): RemoteViews {
        return RemoteViews(context.packageName, R.layout.love_widget).apply {

            // Тап по парному виджету → открыть приложение сразу на его настройках
            // (вкладка «Виджеты» + раскрытая карточка «Парный виджет»).
            val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("loveapp://widgets/pair")
            )
            setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            // ═══════════ Моя сторона ═══════════
            val myStatus = widgetData.getString("my_status", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val myMessage = widgetData.getString("my_message", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val myMusicTitle = widgetData.getString("my_music_title", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val myMusicArtist = widgetData.getString("my_music_artist", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""

            setTextViewText(R.id.my_status, myStatus)
            setTextViewText(R.id.my_message, myMessage)
            setTextViewText(
                R.id.my_music, when {
                    myMusicTitle.isNotEmpty() && myMusicArtist.isNotEmpty() ->
                        "\u266A $myMusicTitle \u2014 $myMusicArtist"
                    myMusicTitle.isNotEmpty() -> "\u266A $myMusicTitle"
                    else -> ""
                }
            )

            // ── Эмодзи настроения ──
            val myEmojiPath = widgetData.getString("my_mood_emoji_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val myEmojiBitmap = loadScaledBitmap(myEmojiPath, 64, withAlpha = true)
            if (myEmojiBitmap != null) {
                setImageViewBitmap(R.id.my_mood_emoji, getCircularEmoji(myEmojiBitmap))
                setViewVisibility(R.id.my_mood_emoji, View.VISIBLE)
                setViewVisibility(R.id.my_mood_text, View.GONE)
            } else {
                val myMoodLabel = widgetData.getString("my_mood", null)
                    .takeIf { !it.isNullOrEmpty() } ?: ""
                setViewVisibility(R.id.my_mood_emoji, View.GONE)
                setViewVisibility(R.id.my_mood_text, if (myMoodLabel.isNotEmpty()) View.VISIBLE else View.GONE)
                if (myMoodLabel.isNotEmpty()) setTextViewText(R.id.my_mood_text, myMoodLabel)
            }

            // ── Фото как фон + лёгкое затемнение ──
            val myPhotoPath = widgetData.getString("my_photo_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val myBgBitmap = loadScaledBitmap(myPhotoPath, 220)
            if (myBgBitmap != null) {
                setImageViewBitmap(R.id.my_bg_photo, myBgBitmap)
                setViewVisibility(R.id.my_bg_photo, View.VISIBLE)
                setViewVisibility(R.id.my_overlay, View.VISIBLE)
                setTextColor(R.id.my_status, Color.WHITE)
                setTextColor(R.id.my_message, Color.argb(220, 255, 255, 255))
                setTextColor(R.id.my_music, Color.argb(180, 255, 255, 255))
            } else {
                setViewVisibility(R.id.my_bg_photo, View.GONE)
                setViewVisibility(R.id.my_overlay, View.GONE)
                setTextColor(R.id.my_status, Color.argb(204, 0, 0, 0))
                setTextColor(R.id.my_message, Color.argb(153, 0, 0, 0))
                setTextColor(R.id.my_music, Color.argb(136, 0, 0, 0))
            }

            // ── Круглая аватарка ──
            val myAvatarPath = widgetData.getString("my_avatar_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val myAvatarBitmap = loadScaledBitmap(myAvatarPath, 96)
            if (myAvatarBitmap != null) {
                setImageViewBitmap(R.id.my_avatar, getCircularBitmap(myAvatarBitmap))
                setViewVisibility(R.id.my_avatar, View.VISIBLE)
            } else {
                setViewVisibility(R.id.my_avatar, View.GONE)
            }

            // ═══════════ Сторона партнёра ═══════════
            val partnerStatus = widgetData.getString("partner_status", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val partnerMessage = widgetData.getString("partner_message", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val partnerMusicTitle = widgetData.getString("partner_music_title", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""
            val partnerMusicArtist = widgetData.getString("partner_music_artist", null)
                .takeIf { !it.isNullOrEmpty() } ?: ""

            setTextViewText(R.id.partner_status, partnerStatus)
            setTextViewText(R.id.partner_message, partnerMessage)
            setTextViewText(
                R.id.partner_music, when {
                    partnerMusicTitle.isNotEmpty() && partnerMusicArtist.isNotEmpty() ->
                        "\u266A $partnerMusicTitle \u2014 $partnerMusicArtist"
                    partnerMusicTitle.isNotEmpty() -> "\u266A $partnerMusicTitle"
                    else -> ""
                }
            )

            // ── Эмодзи настроения партнёра ──
            val partnerEmojiPath = widgetData.getString("partner_mood_emoji_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val partnerEmojiBitmap = loadScaledBitmap(partnerEmojiPath, 64, withAlpha = true)
            if (partnerEmojiBitmap != null) {
                setImageViewBitmap(R.id.partner_mood_emoji, getCircularEmoji(partnerEmojiBitmap))
                setViewVisibility(R.id.partner_mood_emoji, View.VISIBLE)
                setViewVisibility(R.id.partner_mood_text, View.GONE)
            } else {
                val partnerMoodLabel = widgetData.getString("partner_mood", null)
                    .takeIf { !it.isNullOrEmpty() } ?: ""
                setViewVisibility(R.id.partner_mood_emoji, View.GONE)
                setViewVisibility(R.id.partner_mood_text, if (partnerMoodLabel.isNotEmpty()) View.VISIBLE else View.GONE)
                if (partnerMoodLabel.isNotEmpty()) setTextViewText(R.id.partner_mood_text, partnerMoodLabel)
            }

            // ── Фото партнёра как фон + лёгкое затемнение ──
            val partnerPhotoPath = widgetData.getString("partner_photo_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val partnerBgBitmap = loadScaledBitmap(partnerPhotoPath, 220)
            if (partnerBgBitmap != null) {
                setImageViewBitmap(R.id.partner_bg_photo, partnerBgBitmap)
                setViewVisibility(R.id.partner_bg_photo, View.VISIBLE)
                setViewVisibility(R.id.partner_overlay, View.VISIBLE)
                setTextColor(R.id.partner_status, Color.WHITE)
                setTextColor(R.id.partner_message, Color.argb(220, 255, 255, 255))
                setTextColor(R.id.partner_music, Color.argb(180, 255, 255, 255))
            } else {
                setViewVisibility(R.id.partner_bg_photo, View.GONE)
                setViewVisibility(R.id.partner_overlay, View.GONE)
                setTextColor(R.id.partner_status, Color.argb(204, 0, 0, 0))
                setTextColor(R.id.partner_message, Color.argb(153, 0, 0, 0))
                setTextColor(R.id.partner_music, Color.argb(136, 0, 0, 0))
            }

            // ── Круглая аватарка партнёра ──
            val partnerAvatarPath = widgetData.getString("partner_avatar_path", null)
                .takeIf { !it.isNullOrEmpty() }
            val partnerAvatarBitmap = loadScaledBitmap(partnerAvatarPath, 96)
            if (partnerAvatarBitmap != null) {
                setImageViewBitmap(R.id.partner_avatar, getCircularBitmap(partnerAvatarBitmap))
                setViewVisibility(R.id.partner_avatar, View.VISIBLE)
            } else {
                setViewVisibility(R.id.partner_avatar, View.GONE)
            }
        }
    }

    private fun getCircularEmoji(bitmap: Bitmap): Bitmap {
        val size = minOf(bitmap.width, bitmap.height)
        val scaled = if (bitmap.width != size || bitmap.height != size)
            Bitmap.createScaledBitmap(bitmap, size, size, true) else bitmap
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        return output
    }

    private fun getCircularBitmap(bitmap: Bitmap): Bitmap {
        val size = minOf(bitmap.width, bitmap.height)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint().apply { isAntiAlias = true }
        val srcRect = Rect(
            (bitmap.width - size) / 2,
            (bitmap.height - size) / 2,
            (bitmap.width + size) / 2,
            (bitmap.height + size) / 2
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
        paint.strokeWidth = size * 0.05f
        canvas.drawCircle(radius, radius, radius - paint.strokeWidth / 2f, paint)
        return output
    }

    private fun loadScaledBitmap(path: String?, maxSizePx: Int, withAlpha: Boolean = false): Bitmap? {
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
                inDither = !withAlpha
                inScaled = false
                inPreferredConfig = if (withAlpha) Bitmap.Config.ARGB_8888 else Bitmap.Config.RGB_565
            })
        } catch (e: Throwable) { null }
    }
}
