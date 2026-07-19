import SwiftUI
import WidgetKit
import UIKit

// MARK: - Парный виджет «Togetherly» (дизайн 1:1 с Android love_widget.xml)
// Данные пишет lib/services/widget_service.dart (_syncToNativeWidget).
// Картинки (эмодзи/аватар/фон-фото) зеркалятся в App Group под ios_love_*.

private struct LoveSide {
    let moodEmoji: UIImage?
    let moodText: String
    let status: String
    let message: String
    let musicTitle: String
    let musicArtist: String
    let avatar: UIImage?
    let photo: UIImage?

    var musicLine: String {
        guard !musicTitle.isEmpty else { return "" }
        return musicArtist.isEmpty ? "♪ \(musicTitle)" : "♪ \(musicTitle) — \(musicArtist)"
    }

    /// Сторона совсем без данных (нет ни настроения, ни статуса/сообщения/музыки,
    /// ни аватара/фото). Обе пустые → виджет ещё не привязан к паре.
    var isEmpty: Bool {
        moodEmoji == nil && moodText.isEmpty && status.isEmpty && message.isEmpty
            && musicTitle.isEmpty && avatar == nil && photo == nil
    }
}

private func loadLove() -> (me: LoveSide, partner: LoveSide) {
    let s = Store()
    // ВАЖНО: ключи картинок = те, что реально пишет Flutter
    // (widget_service.dart: my_mood_emoji_path/my_avatar_path/my_photo_path
    // через appGroupReadablePath → путь ВНУТРИ контейнера App Group). Раньше
    // читались несуществующие ios_love_* → эмодзи/аватар на iOS не появлялись.
    let me = LoveSide(
        moodEmoji: s.uiImage("my_mood_emoji_path"),
        moodText: s.string("my_mood"),
        status: s.string("my_status"),
        message: s.string("my_message"),
        musicTitle: s.string("my_music_title"),
        musicArtist: s.string("my_music_artist"),
        avatar: s.uiImage("my_avatar_path"),
        photo: s.uiImage("my_photo_path")
    )
    let partner = LoveSide(
        moodEmoji: s.uiImage("partner_mood_emoji_path"),
        moodText: s.string("partner_mood"),
        status: s.string("partner_status"),
        message: s.string("partner_message"),
        musicTitle: s.string("partner_music_title"),
        musicArtist: s.string("partner_music_artist"),
        avatar: s.uiImage("partner_avatar_path"),
        photo: s.uiImage("partner_photo_path")
    )
    return (me, partner)
}

private struct LovePanel: View {
    let side: LoveSide
    let isLeft: Bool

    private var hasPhoto: Bool { side.photo != nil }
    private var statusColor: Color { hasPhoto ? Color.white : Color.black.opacity(0.8) }
    private var messageColor: Color { hasPhoto ? Color.white.opacity(0.9) : Color.black.opacity(0.6) }
    private var musicColor: Color { hasPhoto ? Color.white.opacity(0.85) : Color.black.opacity(0.53) }

    var body: some View {
        ZStack {
            // Фон панели: фото или цвет. Фото с .frame(maxWidth/Height: .infinity)
            // + .clipped() на ZStack, иначе scaledToFill диктует ширину панели и
            // половины получаются неравными.
            if let photo = side.photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.black.opacity(0.1)
            } else {
                (isLeft ? Color(hex: 0xFFCDD9) : Color(hex: 0xE8DAFF))
            }

            // Центральный контент
            VStack(spacing: 0) {
                if let emoji = side.moodEmoji {
                    Image(uiImage: emoji).resizable().scaledToFit().frame(width: 36, height: 36)
                } else if !side.moodText.isEmpty {
                    Text(side.moodText).font(.system(size: 24))
                }
                if !side.status.isEmpty {
                    Text(side.status)
                        .font(.system(size: 10)).foregroundColor(statusColor)
                        .lineLimit(1).padding(.top, 3)
                }
                if !side.message.isEmpty {
                    Text(side.message)
                        .font(.system(size: 9)).foregroundColor(messageColor)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.top, 2)
                }
                if !side.musicLine.isEmpty {
                    Text(side.musicLine)
                        .font(.system(size: 8)).foregroundColor(musicColor)
                        .lineLimit(1).padding(.top, 3)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Аватарка в нижнем углу
            if let avatar = side.avatar {
                VStack {
                    Spacer()
                    HStack {
                        if isLeft { avatarView(avatar); Spacer() }
                        else { Spacer(); avatarView(avatar) }
                    }
                }
                .padding(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func avatarView(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(width: 26, height: 26).clipShape(Circle())
    }
}

private struct LoveDivider: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1).frame(maxHeight: .infinity)
            Text("♥").font(.system(size: 12)).foregroundColor(Color(hex: 0xFF6B8A))
            Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1).frame(maxHeight: .infinity)
        }
        .frame(width: 20)
        .frame(maxHeight: .infinity)
        .background(Color.white)
    }
}

struct LoveWidgetView: View {
    var body: some View {
        let data = loadLove()
        // «Подключите партнёра» показываем ТОЛЬКО когда пары реально нет
        // (love_widget_group_id пуст = не привязаны к группе). Раньше подсказка
        // висела при любых пустых данных → удалил своё фото / нет настроения, и
        // виджет ложно писал «Подключите партнёра», хотя пара на месте.
        let paired = !Store().string("love_widget_group_id").isEmpty
        if !paired && data.me.isEmpty && data.partner.isEmpty {
            LoveEmptyState().loveContainerBackground()
        } else {
            HStack(spacing: 0) {
                LovePanel(side: data.me, isLeft: true)
                LoveDivider()
                LovePanel(side: data.partner, isLeft: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .loveContainerBackground()
        }
    }
}

/// Пустое состояние парного виджета: мягкий градиент + подсказка подключиться.
private struct LoveEmptyState: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xFFCDD9), Color(hex: 0xE8DAFF)],
                startPoint: .leading, endPoint: .trailing
            )
            VStack(spacing: 6) {
                Text("💞").font(.system(size: 34))
                Text("Подключите партнёра")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.65))
                    .multilineTextAlignment(.center)
                Text("Откройте приложение")
                    .font(.system(size: 10))
                    .foregroundColor(Color.black.opacity(0.45))
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoveWidgetProvider", provider: RefreshProvider()) { _ in
            LoveWidgetView()
        }
        .configurationDisplayName("Парный виджет")
        .description("Статус, настроение и музыка вас обоих.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private extension View {
    @ViewBuilder
    func loveContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(Color.white, for: .widget)
        } else {
            ZStack { Color.white; self }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
