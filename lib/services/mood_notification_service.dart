import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../utils/notification_permission.dart';

/// Сервис постоянного уведомления с настроением на Android.
///
/// Использует foreground-style ongoing notification с Importance.high,
/// чтобы гарантированно появляться на экране блокировки.
/// Канал v3 создаётся при каждом запуске — старый канал удаляется,
/// чтобы избежать кэширования низкого importance Android'ом.
class MoodNotificationService {
  MoodNotificationService._();
  static final MoodNotificationService instance = MoodNotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const int _kNotificationId = 8888;
  static const String _kChannelId = 'mood_lock_screen_v3';
  static const String _kChannelName = 'Настроение';

  // ─────────────────────────────────────────────────────────────────────────
  //  INIT
  // ─────────────────────────────────────────────────────────────────────────

  /// Инициализация (вызывать один раз при старте приложения).
  Future<void> init() async {
    if (_initialized || !Platform.isAndroid) return;
    try {
      const androidSettings = AndroidInitializationSettings(
        '@drawable/ic_notification',
      );
      const initSettings = InitializationSettings(android: androidSettings);
      await _plugin.initialize(settings: initSettings);

      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      // Удаляем устаревшие каналы, чтобы importance не кэшировался.
      // Wrapped separately so a missing API doesn't abort init.
      try {
        await androidPlugin?.deleteNotificationChannel(channelId: 'mood_lock_screen_v2');
        await androidPlugin?.deleteNotificationChannel(channelId: 'mood_lock_screen_v1');
        await androidPlugin?.deleteNotificationChannel(channelId: 'mood_lock_screen');
      } catch (_) {}

      // HIGH importance — единственный надёжный способ показать уведомление
      // на экране блокировки без отдельного разрешения MANAGE_OVERLAY на Android 12+
      const channel = AndroidNotificationChannel(
        _kChannelId,
        _kChannelName,
        description: 'Настроение на экране блокировки',
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      );
      await androidPlugin?.createNotificationChannel(channel);

      _initialized = true;
      debugPrint('MoodNotificationService: initialized');
    } catch (e) {
      debugPrint('MoodNotificationService.init failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  SHOW / HIDE
  // ─────────────────────────────────────────────────────────────────────────

  /// Показать / обновить постоянное уведомление с настроением.
  Future<void> show({
    required String myMood,
    required String myName,
    String partnerMood = '',
    String partnerName = '',
  }) async {
    if (!Platform.isAndroid) return;
    if (!_initialized) await init();

    // Android 13+ требует явного запроса разрешения POST_NOTIFICATIONS.
    // Запрашиваем именно здесь — пользователь уже выбрал включить фичу.
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await requestNotificationPermissionSafely(androidPlugin);
    if (!granted) {
      debugPrint('MoodNotificationService: notification permission denied');
      return;
    }

    final title = _buildTitle(myName, myMood);
    final body = _buildBody(partnerName, partnerMood);

    final androidDetails = AndroidNotificationDetails(
      _kChannelId,
      _kChannelName,
      channelDescription: 'Настроение на экране блокировки',
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      showWhen: false,
      icon: '@drawable/ic_notification',
      color: const Color(0xFFEC4899),
      // PUBLIC — содержимое видно без разблокировки
      visibility: NotificationVisibility.public,
      channelShowBadge: false,
      playSound: false,
      enableVibration: false,
      silent: true,
      // Позволяет обновлять уведомление без нового звука/вибрации
      onlyAlertOnce: true,
    );

    try {
      await _plugin.show(
        id: _kNotificationId,
        title: title,
        body: body.isNotEmpty ? body : null,
        notificationDetails: NotificationDetails(android: androidDetails),
      );
      debugPrint('MoodNotificationService: shown — $title | $body');
    } catch (e) {
      debugPrint('MoodNotificationService.show failed: $e');
    }
  }

  /// Скрыть постоянное уведомление.
  Future<void> hide() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.cancel(id: _kNotificationId);
      debugPrint('MoodNotificationService: hidden');
    } catch (e) {
      debugPrint('MoodNotificationService.hide failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  String _buildTitle(String name, String mood) {
    if (mood.isEmpty) return '😶 Настроение не задано';
    final emoji = _moodToEmoji(mood);
    if (name.isNotEmpty) return '$emoji $name: $mood';
    return '$emoji Моё настроение: $mood';
  }

  String _buildBody(String partnerName, String partnerMood) {
    if (partnerMood.isEmpty) return '';
    final emoji = _moodToEmoji(partnerMood);
    if (partnerName.isNotEmpty) return '$emoji $partnerName: $partnerMood';
    return '$emoji Партнёр: $partnerMood';
  }

  String _moodToEmoji(String label) {
    final l = label.toLowerCase();
    if (l.contains('сча') || l.contains('счасть') || l.contains('happ')) return '😊';
    if (l.contains('люблю') || l.contains('влюб') || l.contains('love') || l.contains('star')) return '🥰';
    if (l.contains('целую') || l.contains('kiss')) return '😘';
    if (l.contains('смех') || l.contains('laughing') || l.contains('rofl')) return '😂';
    if (l.contains('гордость') || l.contains('pride')) return '😏';
    if (l.contains('подмигив') || l.contains('wink')) return '😜';
    if (l.contains('смущен') || l.contains('blush') || l.contains('embarr')) return '😊';
    if (l.contains('нет эмоц') || l.contains('no mood') || l.contains('unamused')) return '😐';
    if (l.contains('скучаю') || l.contains('missing')) return '🥺';
    if (l.contains('очень груст') || l.contains('very sad') || l.contains('sobbing')) return '😭';
    if (l.contains('груст') || l.contains('sad')) return '😢';
    if (l.contains('обида') || l.contains('hurt')) return '😤';
    if (l.contains('тревог') || l.contains('anxious')) return '😰';
    if (l.contains('болен') || l.contains('sick') || l.contains('fever')) return '🤒';
    if (l.contains('страх') || l.contains('scared') || l.contains('fear')) return '😨';
    if (l.contains('злость') || l.contains('злост') || l.contains('angry') || l.contains('rage')) return '😠';
    if (l.contains('дьявол') || l.contains('devil')) return '😈';
    if (l.contains('крутой') || l.contains('cool') || l.contains('спок')) return '😎';
    if (l.contains('врунишка') || l.contains('liar')) return '🤥';
    if (l.contains('слюни') || l.contains('drooling')) return '🤤';
    if (l.contains('удивление') || l.contains('surprised')) return '😲';
    if (l.contains('устал') || l.contains('tired') || l.contains('dead')) return '😵';
    if (l.contains('плач') || l.contains('cry')) return '😭';
    return '😶';
  }
}
