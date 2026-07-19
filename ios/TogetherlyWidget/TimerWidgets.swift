import SwiftUI
import WidgetKit

// MARK: - Таймер / обратный отсчёт (дизайн 1:1 с Android timer_widget.xml)
// Данные пишет lib/services/home_widget_service.dart (syncTimer / syncTimerAndDays).

private struct TimerData {
    let title: String
    let days: Int
    let isCountdown: Bool
    let dateText: String
    let startMs: Int
    let isRomantic: Bool
    let themeIndex: Int
}

private func loadTimer(pointer: String) -> TimerData {
    let s = Store()
    let g = s.latestGroup(pointer)
    return TimerData(
        title: s.string("timer_\(g)_title"),
        days: abs(s.int("timer_\(g)_days")),
        isCountdown: s.bool01("timer_\(g)_is_countdown"),
        dateText: s.string("timer_\(g)_date"),
        startMs: s.int("timer_\(g)_start_ms"),
        isRomantic: s.string("timer_\(g)_is_romantic", "1") == "1",
        themeIndex: s.int("timer_\(g)_petal_theme")
    )
}

// Цвета темы таймера (романтика / нейтраль) — точно из timer_widget.xml + drawables.
private struct TimerTheme {
    let bgStart: Color, bgEnd: Color, stroke: Color
    let title: Color, number: Color, label: Color, date: Color

    static func of(romantic: Bool) -> TimerTheme {
        romantic
            ? TimerTheme(bgStart: Color(hex: 0xFDF2F8), bgEnd: Color(hex: 0xEDE9FE),
                         stroke: Color(hex: 0xEDD5EA),
                         title: Color(hex: 0xC084B8), number: Color(hex: 0xB5488A),
                         label: Color(hex: 0x9B7AA8), date: Color(hex: 0xC4A8D4))
            : TimerTheme(bgStart: Color(hex: 0xFFFBF0), bgEnd: Color(hex: 0xFEF3C7),
                         stroke: Color(hex: 0xE8D5A3),
                         title: Color(hex: 0x9C7A3A), number: Color(hex: 0xC2760A),
                         label: Color(hex: 0xA8936A), date: Color(hex: 0xC4B080))
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [bgStart, bgEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct TimerWidgetView: View {
    var body: some View {
        let t = loadTimer(pointer: "timer_latest_group")
        let theme = TimerTheme.of(romantic: t.isRomantic)

        ZStack {
            // Декоративный водяной знак (сердце/звезда) справа по центру
            HStack {
                Spacer()
                TimerThemeIcon(romantic: t.isRomantic)
                    .frame(width: 90, height: 90)
                    .opacity(0.12)
                    .padding(.trailing, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    TimerThemeIcon(romantic: t.isRomantic).frame(width: 14, height: 14)
                    Text(t.title.isEmpty ? "Таймер" : t.title)
                        .font(.system(size: 10))
                        .foregroundColor(theme.title)
                        .lineLimit(1)
                }
                Text("\(t.days)")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(theme.number)
                    .minimumScaleFactor(18.0 / 46.0)
                    .lineLimit(1)
                    .padding(.top, 2)
                Text(t.isCountdown ? "дней осталось" : "дней вместе")
                    .font(.system(size: 11))
                    .foregroundColor(theme.label)
                    .lineLimit(1)
                if !t.dateText.isEmpty {
                    Text(t.dateText)
                        .font(.system(size: 9))
                        .foregroundColor(theme.date)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .padding(.vertical, 12)
        }
        .androidCard(gradient: theme.gradient, stroke: theme.stroke, corner: 22)
    }
}

struct TimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimerWidgetProvider", provider: RefreshProvider()) { _ in
            TimerWidgetView()
        }
        .configurationDisplayName("Таймер")
        .description("Дни вместе или обратный отсчёт до события.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Лепестковый таймер (живой циферблат, дизайн 1:1)
// Android: прозрачный фон + центрированный циферблат (petal_timer_widget.xml).

private let ROMANTIC_BG: [UInt32] = [0x2D1F48, 0x231E3A, 0x1B2035, 0x2A1E18, 0x1A2A1F]
private let ROMANTIC_FG: [UInt32] = [0xFF7E8B, 0x9B86BD, 0x7898BF, 0xCF7E5E, 0x7EA876]
private let NEUTRAL_BG: UInt32 = 0x2A2010
private let NEUTRAL_FG: UInt32 = 0xE8A020

struct PetalTimerWidgetView: View {
    var body: some View {
        let t = loadTimer(pointer: "petal_timer_latest_group")
        let idx = min(max(t.themeIndex, 0), ROMANTIC_BG.count - 1)
        let bg = Color(hex: t.isRomantic ? ROMANTIC_BG[idx] : NEUTRAL_BG)
        let fg = Color(hex: t.isRomantic ? ROMANTIC_FG[idx] : NEUTRAL_FG)
        let petals = computePetals(startMs: t.startMs, countdown: t.isCountdown)

        PetalDial(petals: petals, bg: bg, fg: fg)
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .petalContainerBackground()
    }
}

struct PetalTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PetalTimerWidgetProvider", provider: RefreshProvider()) { _ in
            PetalTimerWidgetView()
        }
        .configurationDisplayName("Лепестковый таймер")
        .description("Живой циферблат: годы, месяцы, дни, часы.")
        // Большой квадрат — циферблат круглый, ему нужна квадратная площадь.
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Хелперы фона

extension View {
    /// Фон-карточка как у Android drawable (градиент + 1pt-штрих + скругление).
    @ViewBuilder
    func androidCard(gradient: LinearGradient, stroke: Color, corner: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            self
                .containerBackground(gradient, for: .widget)
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1)
                )
        } else {
            ZStack {
                gradient
                self
            }
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }

    /// Прозрачный фон для лепесткового виджета (циферблат «парит»).
    @ViewBuilder
    func petalContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.clear, for: .widget)
        } else {
            self
        }
    }
}
