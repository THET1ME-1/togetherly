import SwiftUI
import WidgetKit
import UIKit
import AppIntents

// MARK: - Фото-виджеты (Self / Partner / PhotoDay / Grid)
//
// На Android это PhotoDayWidgetProvider / SelfPhotoWidgetProvider /
// PartnerPhotoWidgetProvider / PhotoGridWidgetProvider. Фото копируются Flutter-ом
// в контейнер App Group (см. AppDelegate.copyToAppGroup + HomeWidgetService
// .syncIosPhotoWidgets), а сюда приходят абсолютные пути под ключами:
//   ios_self_photo_path      — моё фото
//   ios_partner_photo_path   — фото партнёра (+ ios_partner_photo_author)
//   ios_photo_day_path       — «фото дня» (+ ios_photo_day_author)
//   ios_photo_grid_count + ios_photo_grid_0..3 — сетка фото партнёра
//
// kind у каждого виджета совпадает с androidName из HomeWidget.updateWidget,
// чтобы reloadTimelines(ofKind:) перерисовывал нужный виджет.

// MARK: - Общие элементы

private enum PhotoStyle {
    static let corner: CGFloat = 16
    static let placeholderBg = Color(hex: 0xF5F5F5)
    static let placeholderTitle = Color(hex: 0xAAAAAA)
    static let placeholderSubtitle = Color(hex: 0xCCCCCC)
}

/// Одно фото на всю площадь с centerCrop-обрезкой (как scaleType=centerCrop).
private struct PhotoFill: View {
    let image: UIImage?
    var body: some View {
        GeometryReader { geo in
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                PhotoPlaceholder(emojiSize: min(geo.size.width, geo.size.height) * 0.28)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// Плейсхолдер «нет фото» — серый фон + 📷 + подпись (как в Android photo_day_widget).
private struct PhotoPlaceholder: View {
    var emojiSize: CGFloat = 34
    var showText: Bool = true
    var body: some View {
        ZStack {
            PhotoStyle.placeholderBg
            VStack(spacing: 4) {
                Text("📷").font(.system(size: emojiSize))
                if showText {
                    Text("Фото дня")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(PhotoStyle.placeholderTitle)
                    Text("Нет воспоминаний")
                        .font(.system(size: 10))
                        .foregroundColor(PhotoStyle.placeholderSubtitle)
                }
            }
        }
    }
}

/// Обёртка-фон виджета: фото + скругление 16pt. На iOS 17+ обязателен
/// containerBackground, иначе система обрежет содержимое.
private struct PhotoWidgetContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 17.0, *) {
            content()
                .containerBackground(PhotoStyle.placeholderBg, for: .widget)
        } else {
            content()
        }
    }
}

// MARK: - Self / Partner / PhotoDay
//
// Эти три виджета теперь конфигурируемые (iOS 17+) — их определения и
// рендер одиночного фото живут ниже, в секции «Конфигурируемые фото-виджеты».

// MARK: - Photo Grid (1 / 2 / 4 фото)

private struct PhotoGridView: View {
    var body: some View {
        let store = Store()
        let count = max(1, min(4, store.int("ios_photo_grid_count", 1)))
        let images: [UIImage?] = (0..<4).map { store.uiImage("ios_photo_grid_\($0)") }

        PhotoWidgetContainer {
            grid(count: count, images: images)
                .clipShape(RoundedRectangle(cornerRadius: PhotoStyle.corner, style: .continuous))
        }
    }

    @ViewBuilder
    private func grid(count: Int, images: [UIImage?]) -> some View {
        switch count {
        case 2:
            HStack(spacing: 1) {
                cell(images[0])
                cell(images[1])
            }
        case 3, 4:
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    cell(images[0])
                    cell(images[1])
                }
                HStack(spacing: 1) {
                    cell(images[2])
                    cell(images[3])
                }
            }
        default:
            cell(images[0])
        }
    }

    private func cell(_ image: UIImage?) -> some View {
        PhotoFillCell(image: image)
    }
}

/// Ячейка сетки: фото centerCrop либо мелкий плейсхолдер без текста.
private struct PhotoFillCell: View {
    let image: UIImage?
    var body: some View {
        GeometryReader { geo in
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                PhotoPlaceholder(
                    emojiSize: min(geo.size.width, geo.size.height) * 0.3,
                    showText: false
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

struct PhotoGridWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PhotoGridWidgetProvider", provider: RefreshProvider()) { _ in
            PhotoGridView()
        }
        .configurationDisplayName("Сетка фото")
        .description("Несколько фото партнёра в одной сетке.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: Конфигурируемые фото-виджеты (iOS 17+)
//
// На iOS 17+ Self/Partner/PhotoDay становятся настраиваемыми: при долгом тапе
// «Изменить виджет» пользователь выбирает конкретное фото, поэтому несколько
// экземпляров одного виджета могут показывать РАЗНЫЕ фото (как на Android).
//
// Список доступных фото Flutter публикует в App Group JSON-ключами
// ios_photo_catalog_self / _partner / _day (см. HomeWidgetService
// .syncIosPhotoWidgets). Если пользователь ничего не выбрал (photo == nil),
// показываем фото по умолчанию из ios_*_photo_path (как раньше).
//
// Для iOS ≤16 в TogetherlyWidgetBundle остаются статические версии выше.

/// Одна запись каталога фото из App Group.
private struct PhotoCatalogItem: Codable {
    let id: String
    let label: String
    let path: String
}

@available(iOS 17.0, *)
private func loadPhotoCatalog(_ key: String) -> [PhotoCatalogItem] {
    guard let json = AppGroup.defaults?.string(forKey: key),
          let data = json.data(using: .utf8),
          let items = try? JSONDecoder().decode([PhotoCatalogItem].self, from: data)
    else { return [] }
    return items
}

// MARK: - AppEntity + EntityQuery на каждый scope (self / partner / day)

@available(iOS 17.0, *)
struct SelfPhotoEntity: AppEntity {
    let id: String
    let label: String
    let path: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Моё фото"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
    static var defaultQuery = SelfPhotoQuery()
}

@available(iOS 17.0, *)
struct SelfPhotoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SelfPhotoEntity] {
        loadPhotoCatalog("ios_photo_catalog_self")
            .filter { identifiers.contains($0.id) }
            .map { SelfPhotoEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
    func suggestedEntities() async throws -> [SelfPhotoEntity] {
        loadPhotoCatalog("ios_photo_catalog_self")
            .map { SelfPhotoEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
}

@available(iOS 17.0, *)
struct PartnerPhotoEntity: AppEntity {
    let id: String
    let label: String
    let path: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Фото партнёра"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
    static var defaultQuery = PartnerPhotoQuery()
}

@available(iOS 17.0, *)
struct PartnerPhotoQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PartnerPhotoEntity] {
        loadPhotoCatalog("ios_photo_catalog_partner")
            .filter { identifiers.contains($0.id) }
            .map { PartnerPhotoEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
    func suggestedEntities() async throws -> [PartnerPhotoEntity] {
        loadPhotoCatalog("ios_photo_catalog_partner")
            .map { PartnerPhotoEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
}

@available(iOS 17.0, *)
struct PhotoDayEntity: AppEntity {
    let id: String
    let label: String
    let path: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Фото дня"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }
    static var defaultQuery = PhotoDayQuery()
}

@available(iOS 17.0, *)
struct PhotoDayQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PhotoDayEntity] {
        loadPhotoCatalog("ios_photo_catalog_day")
            .filter { identifiers.contains($0.id) }
            .map { PhotoDayEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
    func suggestedEntities() async throws -> [PhotoDayEntity] {
        loadPhotoCatalog("ios_photo_catalog_day")
            .map { PhotoDayEntity(id: $0.id, label: $0.label, path: $0.path) }
    }
}

// MARK: - Intents (один на виджет), объединённые протоколом для общего провайдера

@available(iOS 17.0, *)
protocol PhotoSelectionIntent: WidgetConfigurationIntent {
    /// Путь выбранного фото или nil — тогда берётся фото по умолчанию.
    var selectedPath: String? { get }
    /// Ключ App Group с фото по умолчанию (когда ничего не выбрано).
    var fallbackKey: String { get }
}

@available(iOS 17.0, *)
struct SelectSelfPhotoIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Моё фото"
    static var description = IntentDescription("Выберите, какое фото показывать в виджете.")
    @Parameter(title: "Фото") var photo: SelfPhotoEntity?
    init() {}
}

@available(iOS 17.0, *)
extension SelectSelfPhotoIntent: PhotoSelectionIntent {
    var selectedPath: String? { photo?.path }
    var fallbackKey: String { "ios_self_photo_path" }
}

@available(iOS 17.0, *)
struct SelectPartnerPhotoIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Фото партнёра"
    static var description = IntentDescription("Выберите, какое фото партнёра показывать в виджете.")
    @Parameter(title: "Фото") var photo: PartnerPhotoEntity?
    init() {}
}

@available(iOS 17.0, *)
extension SelectPartnerPhotoIntent: PhotoSelectionIntent {
    var selectedPath: String? { photo?.path }
    var fallbackKey: String { "ios_partner_photo_path" }
}

@available(iOS 17.0, *)
struct SelectPhotoDayIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Фото дня"
    static var description = IntentDescription("Выберите, какое фото показывать в виджете «Фото дня».")
    @Parameter(title: "Фото") var photo: PhotoDayEntity?
    init() {}
}

@available(iOS 17.0, *)
extension SelectPhotoDayIntent: PhotoSelectionIntent {
    var selectedPath: String? { photo?.path }
    var fallbackKey: String { "ios_photo_day_path" }
}

// MARK: - Общий таймлайн-провайдер для конфигурируемых фото-виджетов

@available(iOS 17.0, *)
struct PhotoConfigEntry: TimelineEntry {
    let date: Date
    let path: String
}

@available(iOS 17.0, *)
struct PhotoConfigProvider<I: PhotoSelectionIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PhotoConfigEntry {
        PhotoConfigEntry(date: Date(), path: "")
    }
    func snapshot(for configuration: I, in context: Context) async -> PhotoConfigEntry {
        makeEntry(configuration)
    }
    func timeline(for configuration: I, in context: Context) async -> Timeline<PhotoConfigEntry> {
        Timeline(entries: [makeEntry(configuration)], policy: .atEnd)
    }
    private func makeEntry(_ c: I) -> PhotoConfigEntry {
        let path = c.selectedPath ?? Store().string(c.fallbackKey)
        return PhotoConfigEntry(date: Date(), path: path)
    }
}

/// Рендер одиночного фото по абсолютному пути (для конфигурируемых виджетов).
@available(iOS 17.0, *)
private struct SinglePhotoPathView: View {
    let path: String
    var body: some View {
        let image = path.isEmpty ? nil : UIImage(contentsOfFile: path)
        PhotoWidgetContainer {
            PhotoFill(image: image)
                .clipShape(RoundedRectangle(cornerRadius: PhotoStyle.corner, style: .continuous))
        }
    }
}

// MARK: - Конфигурируемые виджеты (тот же kind, что у статических версий)

@available(iOS 17.0, *)
struct SelfPhotoWidgetConfigurable: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "SelfPhotoWidgetProvider",
            intent: SelectSelfPhotoIntent.self,
            provider: PhotoConfigProvider<SelectSelfPhotoIntent>()
        ) { entry in
            SinglePhotoPathView(path: entry.path)
        }
        .configurationDisplayName("Моё фото")
        .description("Фото, которым вы делитесь с партнёром.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@available(iOS 17.0, *)
struct PartnerPhotoWidgetConfigurable: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "PartnerPhotoWidgetProvider",
            intent: SelectPartnerPhotoIntent.self,
            provider: PhotoConfigProvider<SelectPartnerPhotoIntent>()
        ) { entry in
            SinglePhotoPathView(path: entry.path)
        }
        .configurationDisplayName("Фото партнёра")
        .description("Фото, которым с вами поделился партнёр.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@available(iOS 17.0, *)
struct PhotoDayWidgetConfigurable: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "PhotoDayWidgetProvider",
            intent: SelectPhotoDayIntent.self,
            provider: PhotoConfigProvider<SelectPhotoDayIntent>()
        ) { entry in
            SinglePhotoPathView(path: entry.path)
        }
        .configurationDisplayName("Фото дня")
        .description("Тёплое фото из ваших воспоминаний.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
