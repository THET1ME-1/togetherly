import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Канал для копирования фото в контейнер App Group, чтобы расширение
  /// виджета (TogetherlyWidget) могло читать изображения. Файлы из обычного
  /// app-sandbox (getApplicationSupportDirectory) виджету недоступны.
  private var widgetMediaChannel: FlutterMethodChannel?

  /// Идентификатор App Group — совпадает с entitlements Runner и виджета.
  private static let appGroupId = "group.com.togetherly.love"

  /// Подкаталог внутри контейнера App Group, куда складываем медиа виджетов.
  private static let widgetMediaDir = "widget_media"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Без делегата iOS не показывает локальные уведомления, пока приложение
    // открыто: отвечать на willPresent некому, и баннер не рисуется. Плагин
    // flutter_local_notifications ставит делегата сам только на macOS, на iOS
    // это делается здесь (см. пример плагина, ios/Runner/AppDelegate.swift).
    //
    // Вместе с отсутствием APNs это давало «уведомления не приходят вообще»:
    // в фоне их нет, потому что сокет мёртв, а на переднем плане — из-за этой
    // строки.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupWidgetMediaChannel(engineBridge.pluginRegistry)
  }

  // MARK: - Мост медиа виджетов

  private func setupWidgetMediaChannel(_ registry: FlutterPluginRegistry) {
    guard let messenger = registry
      .registrar(forPlugin: "TogetherlyWidgetMedia")?
      .messenger()
    else { return }

    let channel = FlutterMethodChannel(
      name: "love_app/ios_widget_media",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "copyToAppGroup":
        let args = call.arguments as? [String: Any]
        let srcPath = args?["srcPath"] as? String ?? ""
        let name = args?["name"] as? String ?? ""
        result(self?.copyToAppGroup(srcPath: srcPath, name: name))
      case "clearAppGroupMedia":
        let prefix = (call.arguments as? [String: Any])?["prefix"] as? String ?? ""
        self?.clearAppGroupMedia(prefix: prefix)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetMediaChannel = channel
  }

  /// Каталог `widget_media` внутри контейнера App Group (создаёт при отсутствии).
  private func widgetMediaDirectory() -> URL? {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: AppDelegate.appGroupId
    ) else { return nil }
    let dir = container.appendingPathComponent(AppDelegate.widgetMediaDir, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true
      )
    }
    return dir
  }

  /// Копирует файл `srcPath` в контейнер App Group под именем `<name>.jpg`.
  /// Возвращает абсолютный путь внутри контейнера (читается расширением виджета)
  /// или nil при ошибке.
  private func copyToAppGroup(srcPath: String, name: String) -> String? {
    guard !srcPath.isEmpty, !name.isEmpty,
          FileManager.default.fileExists(atPath: srcPath),
          let dir = widgetMediaDirectory()
    else { return nil }

    let safeName = name.replacingOccurrences(of: "/", with: "_")
    let dest = dir.appendingPathComponent("\(safeName).jpg")
    do {
      if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
      }
      try FileManager.default.copyItem(atPath: srcPath, toPath: dest.path)
      return dest.path
    } catch {
      return nil
    }
  }

  /// Удаляет файлы медиа виджетов, чьи имена начинаются с `prefix`
  /// (пустой prefix — очищает весь каталог).
  private func clearAppGroupMedia(prefix: String) {
    guard let dir = widgetMediaDirectory() else { return }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for file in files where prefix.isEmpty || file.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
    }
  }
}
