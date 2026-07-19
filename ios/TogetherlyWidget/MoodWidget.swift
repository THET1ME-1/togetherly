import SwiftUI
import WidgetKit
import UIKit

// MARK: - Настроение пары (дизайн 1:1 с Android mood_widget.xml)
// Данные: home_widget_service.dart syncMood. Две половины с «водяным сердцем»,
// уровень которого зависит от оценки (0–5). Цвет — из mood_<g>_user_n_color.
// Аватарки зеркалятся в App Group под ios_mood_user_<n>_avatar.

private struct MoodHalf {
    let label: String
    let color: Color
    let fillLevel: CGFloat
    let avatar: UIImage?
}

private func loadMoodHalf(_ s: Store, _ g: String, _ i: Int) -> MoodHalf {
    let score = min(max(s.int("mood_\(g)_user_\(i)_score"), 0), 5)
    let t = Double(score) / 5.0
    let eased = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
    let label = {
        let l = s.string("mood_\(g)_user_\(i)_label")
        return l.isEmpty ? s.string("user_\(i)_label") : l
    }()
    return MoodHalf(
        label: label,
        color: Color(css: s.string("mood_\(g)_user_\(i)_color"), fallback: Color(hex: 0xD1D5DB)),
        fillLevel: CGFloat(eased),
        avatar: s.uiImage("user_\(i)_avatar_path") // Flutter пишет этот ключ (был ios_mood_*)
    )
}

private struct MoodHalfView: View {
    let half: MoodHalf
    let alignAvatarLeading: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                WaterHeart(fillLevel: half.fillLevel, color: half.color)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !half.label.isEmpty {
                    Text(half.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .shadow(color: Color.black.opacity(0.6), radius: 3, x: 0, y: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.4))
                        )
                        .padding(.bottom, 8)
                }
            }
            // Аватарка в нижнем углу
            if let avatar = half.avatar {
                VStack {
                    Spacer()
                    HStack {
                        if alignAvatarLeading {
                            avatarCircle(avatar)
                            Spacer()
                        } else {
                            Spacer()
                            avatarCircle(avatar)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func avatarCircle(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 24, height: 24)
            .clipShape(Circle())
    }
}

struct MoodWidgetView: View {
    var body: some View {
        let s = Store()
        let g = s.latestGroup("mood_latest_group")
        let me = loadMoodHalf(s, g, 0)
        let partner = loadMoodHalf(s, g, 1)

        HStack(spacing: 0) {
            MoodHalfView(half: me, alignAvatarLeading: true)
            MoodHalfView(half: partner, alignAvatarLeading: false)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .petalContainerBackground()
    }
}

struct MoodWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MoodWidgetProvider", provider: RefreshProvider()) { _ in
            MoodWidgetView()
        }
        .configurationDisplayName("Настроение пары")
        .description("Настроение и оценка дня вас обоих.")
        .supportedFamilies([.systemMedium])
    }
}
