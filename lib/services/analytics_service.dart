import 'package:flutter/widgets.dart';

/// Аналитика отключена в рамках ухода с Firebase (firebase_analytics убран).
///
/// Класс сохранён как no-op shell, чтобы не трогать ~десятки call-site'ов
/// (`logMemoryAdded`/`logMoodSet`/…): методы ничего не делают, `observer` —
/// пустой [NavigatorObserver]. Если понадобится своя серверная аналитика на
/// PocketBase — реализацию добавлять сюда, API call-site'ов не меняется.
class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  /// Пустой observer для `MaterialApp.navigatorObservers` (раньше слал
  /// screen_view в Firebase Analytics).
  final NavigatorObserver observer = NavigatorObserver();

  Future<void> setUserId(String? uid) async {}

  // ── Product events (no-op) ──────────────────────────────────────────────
  Future<void> logPairConnected({required String groupId}) async {}
  Future<void> logMemoryAdded({required String type}) async {}
  Future<void> logMoodSet({required String label}) async {}
  Future<void> logCanvasOpened({required bool shared}) async {}
  Future<void> logVibeSent({required String vibeType}) async {}
  Future<void> logMissYouSent() async {}
}
