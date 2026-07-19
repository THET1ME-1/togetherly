import SwiftUI
import WidgetKit

// MARK: - Точка входа расширения

@main
struct TogetherlyWidgetBundle: WidgetBundle {
    // Разбито на два под-блока: один @WidgetBundleBuilder-блок поддерживает
    // не более 10 виджетов, а у нас их 11.
    @WidgetBundleBuilder
    var body: some Widget {
        coreWidgets
        photoWidgets
    }

    @WidgetBundleBuilder
    var coreWidgets: some Widget {
        LoveWidget()
        DaysCounterWidget()
        TimerWidget()
        PetalTimerWidget()
        MoodWidget()
        StreakWidget()
        RelationshipStatsWidget()
    }

    @WidgetBundleBuilder
    var photoWidgets: some Widget {
        // Self/Partner/PhotoDay — конфигурируемые (выбор фото на экземпляр),
        // требуют iOS 17+ (AppIntentConfiguration). WidgetBundleBuilder
        // поддерживает только одиночный `if #available` (buildLimitedAvailability);
        // if/else и #unavailable он не компилирует, поэтому fallback на iOS ≤16
        // для этих виджетов не делаем — там доступна только «Сетка фото».
        PhotoGridWidget()
        if #available(iOS 17.0, *) {
            SelfPhotoWidgetConfigurable()
            PartnerPhotoWidgetConfigurable()
            PhotoDayWidgetConfigurable()
        }
    }
}

// MARK: - Общий таймлайн-провайдер

/// Виджеты не держат данные в Entry — каждый View читает свежие данные из
/// App Group в момент отрисовки. Поэтому Entry несёт только дату, а провайдер
/// один на всех. Flutter дёргает `WidgetCenter.reloadTimelines(ofKind:)` через
/// `HomeWidget.updateWidget(name:)` при каждом изменении данных → виджет
/// перерисовывается мгновенно. Дополнительные точки таймлайна держат
/// «дни/часы» актуальными, даже если приложение не открывали.
struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct RefreshProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let now = Date()
        var entries: [SimpleEntry] = []
        // Обновляемся каждые 15 минут в течение часа, затем система запросит ещё.
        for offset in stride(from: 0, through: 45, by: 15) {
            if let d = Calendar.current.date(byAdding: .minute, value: offset, to: now) {
                entries.append(SimpleEntry(date: d))
            }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Фон карточки (совместимо с iOS 14–17+)

extension View {
    /// Единый фон-градиент. На iOS 17+ используется `containerBackground`
    /// (обязателен, иначе виджет обрезается), на ранних — ZStack.
    @ViewBuilder
    func widgetCardBackground(_ accent: Color) -> some View {
        let gradient = LinearGradient(
            colors: [Palette.cardBackground, accent.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { gradient }
        } else {
            ZStack {
                gradient
                self
            }
        }
    }
}
