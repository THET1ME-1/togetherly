import SwiftUI
import WidgetKit
import UIKit

// MARK: - Дней вместе (дизайн 1:1 с Android days_counter_widget.xml)
// Данные: home_widget_service.dart syncDaysCounter / syncTimerAndDays.

private func yearsText(_ totalDays: Int) -> String {
    let years = totalDays / 365
    let n100 = years % 100, n10 = years % 10
    let word: String
    if n10 == 1 && n100 != 11 { word = "год" }
    else if (2...4).contains(n10) && (n100 < 10 || n100 >= 20) { word = "года" }
    else { word = "лет" }
    return "\(years) \(word) уже ❤️"
}

struct DaysCounterWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = Store()
        let g = s.latestGroup("days_counter_latest_group")
        let count = s.int("days_\(g)_count")
        let date = s.string("days_\(g)_start_date")
        let myGender = s.string("days_\(g)_my_gender", "male")
        let partnerGender = s.string("days_\(g)_partner_gender", "female")
        let usePhotos = s.bool01("days_\(g)_use_photos")
        // Ключи = те, что пишет Flutter (home_widget_service.dart:817
        // days_${g}_my_avatar_path через appGroupReadablePath). Были
        // несуществующие ios_days_* → аватары на iOS не показывались.
        let myAvatar = s.uiImage("days_\(g)_my_avatar_path")
        let partnerAvatar = s.uiImage("days_\(g)_partner_avatar_path")
        let showAvatars = usePhotos && myAvatar != nil && partnerAvatar != nil

        let coupleName: String = {
            if myGender == "female" && partnerGender == "female" { return "widget_couple_ff" }
            if myGender == "male" && partnerGender == "male" { return "widget_couple_mm" }
            return "widget_couple_mf"
        }()
        let flip = myGender == "female" && partnerGender == "male"
        let brown = Color(hex: 0x5D4037)
        // Крупнее на большом (квадрат 4×4); маленький — как было.
        let k: CGFloat = family == .systemLarge ? 1.9 : 1.0

        ZStack {
            // Низ: рисунок пары ИЛИ две аватарки
            VStack {
                Spacer(minLength: 0)
                if showAvatars {
                    HStack(spacing: -10 * k) {
                        avatarCircle(myAvatar!, size: 56 * k)
                        avatarCircle(partnerAvatar!, size: 56 * k)
                    }
                    .padding(.bottom, 14 * k)
                } else {
                    Image(coupleName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .scaleEffect(x: flip ? -1 : 1, y: 1)
                }
            }

            // Верх: «N лет уже ❤️»
            VStack {
                Text(yearsText(count))
                    .font(.system(size: 12 * k, weight: .bold))
                    .foregroundColor(brown)
                    .padding(.top, 16 * k)
                Spacer(minLength: 0)
            }

            // Центр: число дней / «дней» / дата
            VStack(spacing: 0) {
                Text("\(count)")
                    .font(.system(size: 36 * k, weight: .bold))
                    .foregroundColor(brown)
                Text("дней")
                    .font(.system(size: 14 * k, weight: .bold))
                    .foregroundColor(brown)
                    .padding(.top, -2)
                if !date.isEmpty {
                    Text(date)
                        .font(.system(size: 10 * k, weight: .bold))
                        .foregroundColor(brown)
                        .padding(.top, 8 * k)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pinkBorderCard()
    }

    private func avatarCircle(_ image: UIImage, size: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

struct DaysCounterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DaysCounterWidgetProvider", provider: RefreshProvider()) { _ in
            DaysCounterWidgetView()
        }
        .configurationDisplayName("Дней вместе")
        .description("Сколько дней вы вместе.")
        .supportedFamilies([.systemSmall, .systemLarge])
    }
}

// MARK: - Огонёк пары / серия (дизайн 1:1 с Android streak_widget.xml)

private func pluralDays(_ n: Int) -> String {
    let n100 = n % 100, n10 = n % 10
    if n10 == 1 && n100 != 11 { return "день" }
    if (2...4).contains(n10) && (n100 < 10 || n100 >= 20) { return "дня" }
    return "дней"
}

private func streakAlive(lastDate: String) -> Bool {
    guard !lastDate.isEmpty else { return false }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    guard let last = f.date(from: lastDate) else { return false }
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: last),
                                  to: cal.startOfDay(for: Date())).day ?? 99
    return days == 0 || days == 1 // сегодня или вчера
}

struct StreakWidgetView: View {
    var body: some View {
        let s = Store()
        let stored = s.int("streak_days")
        let record = s.int("streak_record")
        let alive = streakAlive(lastDate: s.string("streak_last_date"))
        let days = alive ? stored : 0
        let warm = alive && days > 0

        let sub: String = {
            if !warm { return "Зайдите вдвоём сегодня" }
            if record > days { return "Рекорд: \(record) \(pluralDays(record))" }
            if days >= 7 { return "Так держать! 🔥" }
            return "Заходите каждый день"
        }()

        let gradient = warm
            ? LinearGradient(colors: [Color(hex: 0xFFB23E), Color(hex: 0xFF6A3D), Color(hex: 0xF9417B)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(hex: 0x7E8AA0), Color(hex: 0x5E6A7E), Color(hex: 0x454F61)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)

        ZStack {
            // Декоративный большой огонёк справа
            HStack {
                Spacer()
                StreakFlame(warm: warm)
                    .frame(width: 120, height: 120)
                    .opacity(0.16)
                    .padding(.trailing, -18)
            }

            HStack(spacing: 12) {
                StreakFlame(warm: warm).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 1) {
                    Text("СЕРИЯ ВМЕСТЕ")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.9))
                        .lineLimit(1)
                    Text("\(days)")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundColor(.white)
                        .minimumScaleFactor(20.0 / 46.0)
                        .lineLimit(1)
                    Text("\(pluralDays(days)) подряд")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.95))
                        .lineLimit(1)
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .androidCard(
            gradient: gradient,
            stroke: Color.white.opacity(warm ? 0.2 : 0.13),
            corner: 24
        )
    }
}

struct StreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StreakWidgetProvider", provider: RefreshProvider()) { _ in
            StreakWidgetView()
        }
        .configurationDisplayName("Огонёк пары")
        .description("Сколько дней подряд вы заходите вместе.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Статистика отношений (дизайн 1:1 с relationship_stats_widget.xml)
// 2×2 сетка градиентных карточек.

private struct StatCard: View {
    let value: Int
    let label: String
    let symbol: String
    let iconColor: Color
    let gradStart: Color
    let gradEnd: Color
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle().fill(Color.white).frame(width: 32 * scale, height: 32 * scale)
                Image(systemName: symbol)
                    .font(.system(size: 16 * scale))
                    .foregroundColor(iconColor)
            }
            Text("\(value)")
                .font(.system(size: 22 * scale, weight: .bold))
                .foregroundColor(Color(hex: 0x212121))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8 * scale)
            Text(label)
                .font(.system(size: 10 * scale))
                .foregroundColor(Color(hex: 0x757575))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12 * scale)
        .background(
            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                .fill(LinearGradient(colors: [gradStart, gradEnd],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }
}

struct RelationshipStatsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let s = Store()
        let g = s.latestGroup("stats_latest_group")
        let days = s.int("stats_\(g)_days")
        let memories = s.int("stats_\(g)_memories")
        let drawings = s.int("stats_\(g)_drawings")
        let missYou = s.int("stats_\(g)_miss_you")
        // Высокий вариант (квадрат 4×4) — крупнее карточки/цифры.
        let k: CGFloat = family == .systemLarge ? 1.6 : 1.0

        VStack(spacing: 8 * k) {
            HStack(spacing: 8 * k) {
                StatCard(value: days, label: s.string("stats_\(g)_days_label", "дней"),
                         symbol: "calendar", iconColor: Color(hex: 0xE91E63),
                         gradStart: Color(hex: 0xFCE4EC), gradEnd: Color(hex: 0xF8BBD0), scale: k)
                StatCard(value: memories, label: s.string("stats_\(g)_memories_label", "моментов"),
                         symbol: "photo.fill", iconColor: Color(hex: 0x2196F3),
                         gradStart: Color(hex: 0xE3F2FD), gradEnd: Color(hex: 0xBBDEFB), scale: k)
            }
            HStack(spacing: 8 * k) {
                StatCard(value: drawings, label: s.string("stats_\(g)_drawings_label", "рисунков"),
                         symbol: "paintbrush.fill", iconColor: Color(hex: 0xFFA000),
                         gradStart: Color(hex: 0xFFF8E1), gradEnd: Color(hex: 0xFFECB3), scale: k)
                StatCard(value: missYou, label: s.string("stats_\(g)_miss_you_label", "скучаю"),
                         symbol: "heart.fill", iconColor: Color(hex: 0x9C27B0),
                         gradStart: Color(hex: 0xF3E5F5), gradEnd: Color(hex: 0xE1BEE7), scale: k)
            }
        }
        .padding(8 * k)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .statsContainerBackground()
    }
}

struct RelationshipStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RelationshipStatsWidgetProvider", provider: RefreshProvider()) { _ in
            RelationshipStatsWidgetView()
        }
        .configurationDisplayName("Статистика отношений")
        .description("Дни, моменты, рисунки и «я скучаю».")
        // Высокий вариант (квадрат 4×4) — карточки 2×2 становятся крупными.
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Хелперы фона

private extension View {
    /// Белая карточка с розовой рамкой 3pt (Days, widget_bg_pink_border).
    @ViewBuilder
    func pinkBorderCard() -> some View {
        if #available(iOS 17.0, *) {
            self
                .containerBackground(Color.white, for: .widget)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color(hex: 0xFFD1DC), lineWidth: 3)
                )
        } else {
            ZStack { Color.white; self }
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color(hex: 0xFFD1DC), lineWidth: 3)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    /// Белый фон со скруглением 20pt (Stats, stats_widget_bg).
    @ViewBuilder
    func statsContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(Color.white, for: .widget)
        } else {
            ZStack { Color.white; self }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
