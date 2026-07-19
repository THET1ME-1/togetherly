import SwiftUI
import WidgetKit
import UIKit

// MARK: - App Group

/// Общая «песочница» между приложением Flutter и виджетами.
/// ВАЖНО: это значение должно совпадать с:
///   • HomeWidget.setAppGroupId(...) во Flutter (lib/main.dart);
///   • App Group в Runner.entitlements / RunnerDebug.entitlements;
///   • App Group в TogetherlyWidget.entitlements;
///   • App Group, заведённым в Apple Developer → Identifiers → App Groups.
/// Плагин home_widget на iOS пишет данные в UserDefaults(suiteName: appGroupId)
/// ключами «как есть» — теми же, что в Dart-коде saveWidgetData('key', ...).
enum AppGroup {
    static let id = "group.com.togetherly.love"
    static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}

// MARK: - Чтение значений из App Group

/// Тонкая обёртка над UserDefaults общей группы: единый доступ к ключам,
/// которые пишет Flutter (см. lib/services/home_widget_service.dart и
/// lib/services/widget_service.dart).
struct Store {
    private let d = AppGroup.defaults

    func string(_ key: String, _ fallback: String = "") -> String {
        d?.string(forKey: key) ?? fallback
    }

    /// home_widget пишет числа как через saveWidgetData<int>, так и строками
    /// (saveWidgetData<String>(n.toString())). Читаем устойчиво к обоим вариантам.
    func int(_ key: String, _ fallback: Int = 0) -> Int {
        guard let obj = d?.object(forKey: key) else { return fallback }
        if let n = obj as? Int { return n }
        if let n = obj as? NSNumber { return n.intValue }
        if let s = obj as? String { return Int(s) ?? fallback }
        return fallback
    }

    func bool01(_ key: String) -> Bool { string(key) == "1" }

    /// Загружает изображение по абсолютному пути из контейнера App Group
    /// (туда фото копирует AppDelegate.copyToAppGroup). Путь лежит в значении
    /// ключа [key]; пустой путь / отсутствующий файл → nil.
    func uiImage(_ key: String) -> UIImage? {
        let path = string(key)
        guard !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: path)
    }

    /// Возвращает groupId активной группы для конкретного семейства виджетов.
    /// Flutter пишет указатель «<type>_latest_group», а сами данные лежат под
    /// «<type>_<groupId>_<field>». 'solo'/'' — соло-режим (sentinel из Dart).
    func latestGroup(_ pointerKey: String) -> String {
        let g = string(pointerKey)
        return g.isEmpty ? "solo" : g
    }
}

// MARK: - Темы / цвета

/// Палитра акцентов приложения (см. timer_<g>_petal_theme: 0..4).
enum Palette {
    static let accents: [Color] = [
        Color(hex: 0xFF7E8B), // 0 pink
        Color(hex: 0x9C77FF), // 1 purple
        Color(hex: 0x5AA9FF), // 2 blue
        Color(hex: 0xFF9D5C), // 3 orange
        Color(hex: 0x57C99A), // 4 green
    ]

    static func accent(_ index: Int) -> Color {
        guard index >= 0 && index < accents.count else { return accents[0] }
        return accents[index]
    }

    static let cardBackground = Color(hex: 0xFFFFFF)
    static let cardBackgroundSoft = Color(hex: 0xFFF3F0)
    static let title = Color(hex: 0x2A2A2A)
    static let body = Color(hex: 0x555555)
    static let muted = Color(hex: 0x999999)
}

extension Color {
    /// Цвет из 0xRRGGBB.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Цвет из строки «#RRGGBB» / «RRGGBB» / «0xRRGGBB». Пусто/ошибка → fallback.
    init(css: String, fallback: Color) {
        var s = css.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "#", with: "")
             .replacingOccurrences(of: "0x", with: "")
             .replacingOccurrences(of: "0X", with: "")
        if s.count == 8 { s = String(s.suffix(6)) } // ARGB → RGB
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = fallback
            return
        }
        self.init(hex: v)
    }
}

// MARK: - Общая «карточка»

/// Единый фон-карточка под все виджеты — мягкий градиент в тон акценту.
struct WidgetCard<Content: View>: View {
    var accent: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.cardBackground, accent.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            content()
                .padding(14)
        }
    }
}

// MARK: - Помощники дат/чисел

enum TimeMath {
    /// Разбивает интервал (в секундах) на годы/месяцы/дни/часы/минуты/секунды
    /// приблизительно (для «лепесткового» циферблата достаточно).
    static func breakdown(fromEpochMs ms: Int) -> (y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) {
        guard ms > 0 else { return (0, 0, 0, 0, 0, 0) }
        let start = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let now = Date()
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: min(start, now), to: max(start, now)
        )
        return (
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
            comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0
        )
    }

    /// Целых дней между датой старта (мс) и сейчас (по модулю).
    static func days(fromEpochMs ms: Int) -> Int {
        guard ms > 0 else { return 0 }
        let start = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let secs = abs(Date().timeIntervalSince(start))
        return Int(secs / 86400)
    }
}
