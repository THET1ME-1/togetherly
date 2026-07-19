package com.togetherly.love

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Dynamically-registered receiver for ACTION_USER_PRESENT.
    //
    // On Android 8.0+ implicit broadcasts declared in the manifest are NOT
    // delivered, so the manifest entry for PhotoDayRotationReceiver cannot
    // receive USER_PRESENT on any modern device.  Registering here at runtime
    // solves this: the receiver lives as long as the app process is alive,
    // which covers the common case (user just used the app, locks phone,
    // unlocks → photo changes immediately).  When the process is killed the
    // 15-min AlarmManager fallback takes over.
    //
    // We register on first onStart and unregister only in onDestroy so the
    // receiver stays active even while the activity is in the back-stack.
    private var userPresentReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

    override fun onStart() {
        super.onStart()
        if (userPresentReceiver == null) {
            userPresentReceiver = PhotoDayRotationReceiver()
            val filter = IntentFilter(Intent.ACTION_USER_PRESENT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(userPresentReceiver, filter, RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(userPresentReceiver, filter)
            }
        }
    }

    override fun onDestroy() {
        userPresentReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        userPresentReceiver = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "love_app/widgets"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPhotoDayWidgetIds" -> {
                    val manager = AppWidgetManager.getInstance(this)
                    val legacy = manager.getAppWidgetIds(
                        ComponentName(this, PhotoDayWidgetProvider::class.java)
                    ).toList()
                    val selfIds = manager.getAppWidgetIds(
                        ComponentName(this, SelfPhotoWidgetProvider::class.java)
                    ).toList()
                    val partnerIds = manager.getAppWidgetIds(
                        ComponentName(this, PartnerPhotoWidgetProvider::class.java)
                    ).toList()
                    result.success((legacy + selfIds + partnerIds).distinct())
                }

                "getSelfPhotoWidgetIds" -> {
                    val manager = AppWidgetManager.getInstance(this)
                    val component = ComponentName(this, SelfPhotoWidgetProvider::class.java)
                    result.success(manager.getAppWidgetIds(component).toList())
                }

                "getPartnerPhotoWidgetIds" -> {
                    val manager = AppWidgetManager.getInstance(this)
                    val component = ComponentName(this, PartnerPhotoWidgetProvider::class.java)
                    result.success(manager.getAppWidgetIds(component).toList())
                }

                "getPhotoGridWidgetIds" -> {
                    val manager = AppWidgetManager.getInstance(this)
                    val component = ComponentName(this, PhotoGridWidgetProvider::class.java)
                    result.success(manager.getAppWidgetIds(component).toList())
                }

                "updatePhotoDayCarousel" -> {
                    val widgetId = call.argument<Int>("widgetId")
                    val paths = call.argument<List<String>>("paths")
                    // Flutter computes the display index; use it so native receiver
                    // continues advancing from the correct position.
                    val currentIndex = call.argument<Int>("currentIndex") ?: 0

                    if (widgetId != null && paths != null) {
                        val prefs = getSharedPreferences("HomeWidgetPreferences", android.content.Context.MODE_PRIVATE)
                        val storedIndex = prefs.getInt("photo_day_widget_${widgetId}_current_index", -1)
                        val editor = prefs.edit()
                            .putString(
                                "photo_day_widget_${widgetId}_paths",
                                org.json.JSONArray(paths).toString()
                            )
                            .putInt("photo_day_widget_${widgetId}_current_index", currentIndex)

                        // Only update last_update when Flutter actually advanced the index.
                        // For "unlock" mode Flutter always sends the unchanged storedIndex —
                        // writing last_update = now on every sync would prevent the 15-min
                        // alarm fallback from ever firing and the photo would never change.
                        if (currentIndex != storedIndex) {
                            editor.putLong("photo_day_widget_${widgetId}_last_update", System.currentTimeMillis())
                        }
                        editor.apply()

                        PhotoDayWidgetProvider.scheduleRotationAlarm(this)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "Missing widgetId or paths", null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // ── Кастомизация launcher-иконки через activity-alias ──
        // Включает выбранный alias и гасит остальные. DONT_KILL_APP — чтобы по
        // возможности не убивать процесс при смене (поведение зависит от лаунчера).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app_icon"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setIcon" -> {
                    val id = call.argument<String>("id")
                    if (id == null || !ICON_ALIASES.containsKey(id)) {
                        result.error("INVALID_ARGS", "Unknown icon id: $id", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val pm = packageManager
                        for ((aliasId, suffix) in ICON_ALIASES) {
                            val component = ComponentName(packageName, "$packageName$suffix")
                            val state = if (aliasId == id)
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            else
                                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                            pm.setComponentEnabledSetting(
                                component, state, PackageManager.DONT_KILL_APP
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SET_ICON_FAILED", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    companion object {
        // id (тема) -> суффикс android:name alias в манифесте.
        private val ICON_ALIASES = linkedMapOf(
            "pink" to ".IconPink",
            "purple" to ".IconPurple",
            "blue" to ".IconBlue",
            "green" to ".IconGreen",
            "midnight" to ".IconMidnight",
            "orange" to ".IconOrange",
            "lavender" to ".IconLavender",
            "cherry" to ".IconCherry",
            "mint" to ".IconMint",
            "sunset" to ".IconSunset",
            "monochrome" to ".IconMonochrome",
            "forest" to ".IconForest",
            "ocean" to ".IconOcean",
        )
    }
}
