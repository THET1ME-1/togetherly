import SwiftUI
import WidgetKit

// MARK: - Порт рисующей графики Android в SwiftUI (1:1)
//
// Формы и математика повторяют Canvas-код провайдеров Android:
//   • StreakFlame   ← StreakWidgetProvider.drawFlame / flamePath
//   • HeartShape    ← TimerWidgetProvider.drawHeart  / MoodWidgetProvider.createHeartPath
//   • StarShape     ← TimerWidgetProvider.drawStar
//   • WaterHeart    ← MoodWidgetProvider.createWaterHeartBitmap
//   • PetalDial     ← PetalTimerWidgetProvider.drawDial / buildSector

// MARK: Контур пламени (нормализован в rect, масштаб вокруг низа-центра)

struct FlameShape: Shape {
    var scale: CGFloat = 1.0

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: x0 + w * fx, y: y0 + h * fy)
        }
        let bottom: CGFloat = 0.97
        var p = Path()
        p.move(to: pt(0.5, 0.05))
        p.addCurve(to: pt(0.78, 0.61), control1: pt(0.70, 0.21), control2: pt(0.82, 0.41))
        p.addCurve(to: pt(0.5, bottom), control1: pt(0.75, 0.81), control2: pt(0.63, bottom))
        p.addCurve(to: pt(0.22, 0.60), control1: pt(0.37, bottom), control2: pt(0.25, 0.81))
        p.addCurve(to: pt(0.41, 0.19), control1: pt(0.20, 0.43), control2: pt(0.35, 0.32))
        p.addCurve(to: pt(0.5, 0.05), control1: pt(0.45, 0.11), control2: pt(0.47, 0.08))
        p.closeSubpath()

        if scale != 1.0 {
            let cx = x0 + w * 0.5
            let by = y0 + h * bottom
            let t = CGAffineTransform(translationX: cx, y: by)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -cx, y: -by)
            return p.applying(t)
        }
        return p
    }
}

/// Огонёк серии: тёплый (горит) или холодный (потух).
struct StreakFlame: View {
    let warm: Bool

    private var tip: Color { warm ? Color(hex: 0xFFE08A) : Color(hex: 0xD7DEE8) }
    private var mid: Color { warm ? Color(hex: 0xFF8A3D) : Color(hex: 0xA6B2C2) }
    private var base: Color { warm ? Color(hex: 0xFF3D6E) : Color(hex: 0x7C8799) }
    private var coreTop: Color { warm ? Color(hex: 0xFFFFFF) : Color(hex: 0xF0F3F7) }
    private var coreBottom: Color { warm ? Color(hex: 0xFFE59A) : Color(hex: 0xC9D2DE) }
    private var glow: Color { warm ? Color(hex: 0xFFB347) : Color(hex: 0xAEB9C7) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Свечение под огоньком
                RadialGradient(
                    gradient: Gradient(colors: [glow.opacity(warm ? 0.47 : 0.235), glow.opacity(0)]),
                    center: UnitPoint(x: 0.5, y: 0.62),
                    startRadius: 0,
                    endRadius: w * 0.52
                )
                .frame(width: w, height: h)
                // Внешнее пламя
                FlameShape().fill(
                    LinearGradient(
                        stops: [
                            .init(color: base, location: 0),
                            .init(color: mid, location: 0.55),
                            .init(color: tip, location: 1),
                        ],
                        startPoint: .bottom, endPoint: .top
                    )
                )
                // Внутреннее ядро
                FlameShape(scale: 0.52).fill(
                    LinearGradient(
                        colors: [coreBottom, coreTop],
                        startPoint: UnitPoint(x: 0.5, y: 0.95),
                        endPoint: UnitPoint(x: 0.5, y: 0.25)
                    )
                )
            }
        }
    }
}

// MARK: Сердце и звезда

struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: x0 + w * fx, y: y0 + h * fy)
        }
        var p = Path()
        p.move(to: pt(0.5, 0.27))
        p.addCurve(to: pt(0.25, 0.14), control1: pt(0.5, 0.245), control2: pt(0.45, 0.14))
        p.addCurve(to: pt(0.0, 0.46), control1: pt(0.0, 0.14), control2: pt(0.0, 0.46))
        p.addCurve(to: pt(0.5, 1.0), control1: pt(0.0, 0.71), control2: pt(0.25, 0.84))
        p.addCurve(to: pt(1.0, 0.46), control1: pt(0.75, 0.84), control2: pt(1.0, 0.71))
        p.addCurve(to: pt(0.75, 0.14), control1: pt(1.0, 0.46), control2: pt(1.0, 0.14))
        p.addCurve(to: pt(0.5, 0.27), control1: pt(0.6, 0.14), control2: pt(0.5, 0.245))
        p.closeSubpath()
        return p
    }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let outerR = size * 0.46, innerR = size * 0.19
        var p = Path()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let r = i % 2 == 0 ? outerR : innerR
            let point = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

/// Декоративная иконка таймера: сердце (романтика) или звезда (нейтраль).
struct TimerThemeIcon: View {
    let romantic: Bool

    var body: some View {
        let grad = romantic
            ? LinearGradient(colors: [Color(hex: 0xD4609A), Color(hex: 0xE891C8)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(hex: 0xE8A020), Color(hex: 0xF5C842)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
        Group {
            if romantic { HeartShape().fill(grad) }
            else { StarShape().fill(grad) }
        }
    }
}

// MARK: Водяное сердце настроения

struct WaterHeart: View {
    /// 0..1 — уровень заполнения (score/maxScore).
    let fillLevel: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Фон-сердце
                HeartShape().fill(color.opacity(20.0 / 255.0))
                // Вода
                if fillLevel > 0.005 {
                    WaterFill(fillLevel: fillLevel, size: size, color: color)
                        .clipShape(HeartShape())
                }
                // Контур
                HeartShape().stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WaterFill: View {
    let fillLevel: CGFloat
    let size: CGFloat
    let color: Color

    var body: some View {
        let waterTop = size * (1 - fillLevel)
        let waveAmp = size * 0.03
        ZStack(alignment: .topLeading) {
            WavePath(waterTop: waterTop, waveAmp: waveAmp, size: size).fill(
                LinearGradient(
                    colors: [color.opacity(0.68), color.opacity(0.90)],
                    startPoint: UnitPoint(x: 0.5, y: waterTop / size),
                    endPoint: .bottom
                )
            )
            if fillLevel > 0.15 {
                Circle()
                    .fill(Color.white.opacity(77.0 / 255.0))
                    .frame(width: size * 0.12, height: size * 0.12)
                    .position(x: size * 0.32, y: waterTop + size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct WavePath: Shape {
    let waterTop: CGFloat
    let waveAmp: CGFloat
    let size: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -1, y: waterTop))
        let steps = 24
        for i in 0...steps {
            let x = size * CGFloat(i) / CGFloat(steps)
            let y = waterTop + sin(x / size * 2 * .pi - .pi * 0.5) * waveAmp
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: size + 1, y: size))
        p.addLine(to: CGPoint(x: -1, y: size))
        p.closeSubpath()
        return p
    }
}

// MARK: Лепестковый циферблат

struct PetalInfo {
    let value: Int
    let label: String
    let factor: CGFloat
}

/// Вычисляет лепестки (порт PetalTimerWidgetProvider.computePetals).
func computePetals(startMs: Int, countdown: Bool) -> [PetalInfo] {
    let zero = [
        PetalInfo(value: 0, label: "лет", factor: 0),
        PetalInfo(value: 0, label: "мес", factor: 0),
        PetalInfo(value: 0, label: "дн", factor: 0),
        PetalInfo(value: 0, label: "ч", factor: 0),
        PetalInfo(value: 0, label: "мин", factor: 0),
        PetalInfo(value: 0, label: "сек", factor: 0),
    ]
    if startMs == 0 { return zero }
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let fromMs = countdown ? nowMs : startMs
    let toMs = countdown ? startMs : nowMs
    if toMs <= fromMs { return zero }

    let cal = Calendar.current
    let fromD = Date(timeIntervalSince1970: Double(fromMs) / 1000)
    let toD = Date(timeIntervalSince1970: Double(toMs) / 1000)
    let comps = cal.dateComponents([.year, .month, .day], from: fromD, to: toD)
    let years = comps.year ?? 0
    let months = comps.month ?? 0
    let days = comps.day ?? 0

    let diffMs = toMs - fromMs
    let hI = (diffMs / 3_600_000) % 24
    let minI = (diffMs / 60_000) % 60
    let sI = (diffMs / 1000) % 60

    func f(_ exact: Double, _ maxV: Double) -> CGFloat {
        maxV > 0 ? CGFloat(min(max(exact / maxV, 0), 1)) : 0
    }
    return [
        PetalInfo(value: years, label: "лет", factor: f(Double(years) + Double(months) / 12.0, 100)),
        PetalInfo(value: months, label: "мес", factor: f(Double(months) + Double(days) / 30.0, 12)),
        PetalInfo(value: days, label: "дн", factor: f(Double(days) + Double(hI) / 24.0, 30)),
        PetalInfo(value: hI, label: "ч", factor: f(Double(hI) + Double(minI) / 60.0, 24)),
        PetalInfo(value: minI, label: "мин", factor: f(Double(minI) + Double(sI) / 60.0, 60)),
        PetalInfo(value: sI, label: "сек", factor: f(Double(sI), 60)),
    ]
}

private func buildSector(outer: CGFloat, inner: CGFloat, h: CGFloat, sweepHalf: CGFloat) -> Path {
    var path = Path()
    if outer <= h || outer <= inner { return path }
    let topA = sweepHalf, botA = -sweepHalf
    let tOut = sqrt(outer * outer - h * h)
    let pOutTop = CGPoint(x: tOut * cos(topA) + h * sin(topA), y: tOut * sin(topA) - h * cos(topA))
    let pOutBot = CGPoint(x: tOut * cos(botA) - h * sin(botA), y: tOut * sin(botA) + h * cos(botA))

    var pInTop = CGPoint.zero
    var pInBot = CGPoint.zero
    if inner > h {
        let tIn = sqrt(inner * inner - h * h)
        pInTop = CGPoint(x: tIn * cos(topA) + h * sin(topA), y: tIn * sin(topA) - h * cos(topA))
        pInBot = CGPoint(x: tIn * cos(botA) - h * sin(botA), y: tIn * sin(botA) + h * cos(botA))
    } else {
        let xInt = h / sin(sweepHalf)
        pInTop = CGPoint(x: xInt, y: 0)
        pInBot = CGPoint(x: xInt, y: 0)
    }

    let aOutTop = atan2(pOutTop.y, pOutTop.x)
    let aOutBot = atan2(pOutBot.y, pOutBot.x)

    path.move(to: pInBot)
    path.addLine(to: pOutBot)
    if aOutTop > aOutBot {
        path.addArc(center: .zero, radius: outer,
                    startAngle: .radians(Double(aOutBot)),
                    endAngle: .radians(Double(aOutTop)), clockwise: false)
    }
    path.addLine(to: pInTop)
    if inner > h {
        let aInTop = atan2(pInTop.y, pInTop.x)
        let aInBot = atan2(pInBot.y, pInBot.x)
        path.addArc(center: .zero, radius: inner,
                    startAngle: .radians(Double(aInTop)),
                    endAngle: .radians(Double(aInBot)), clockwise: true)
    } else {
        path.addLine(to: pInBot)
    }
    path.closeSubpath()
    return path
}

struct PetalDial: View {
    let petals: [PetalInfo]
    let bg: Color
    let fg: Color

    var body: some View {
        if #available(iOS 15.0, *) {
            dialCanvas
        } else {
            PetalDialFallback(petals: petals, bg: bg, fg: fg)
        }
    }

    @available(iOS 15.0, *)
    private var dialCanvas: some View {
        Canvas { ctx, sz in
            let size = min(sz.width, sz.height)
            let scale = size / 280
            let outerR = size / 2 - 2
            let innerR = outerR * 0.15
            let cr = 4 * scale
            let gapWidth = 6 * scale
            let rigidInner = innerR + cr
            let rigidOuter = outerR - cr
            let h = gapWidth / 2 + cr
            let n = CGFloat(petals.count)
            let sweep = 2 * CGFloat.pi / n
            let sweepHalf = sweep / 2
            var startAngle = -CGFloat.pi / 2
            let cx = sz.width / 2, cy = sz.height / 2

            for petal in petals {
                let segAngle = startAngle + sweepHalf
                var c = ctx
                c.translateBy(x: cx, y: cy)
                c.rotate(by: .radians(Double(segAngle)))

                let bgPath = buildSector(outer: rigidOuter, inner: rigidInner, h: h, sweepHalf: sweepHalf)
                c.fill(bgPath, with: .color(bg))
                c.stroke(bgPath, with: .color(bg), style: StrokeStyle(lineWidth: cr * 2, lineJoin: .round))

                if petal.factor > 0.01 {
                    let fgOuter = max(rigidInner + 0.1, innerR + (outerR - innerR) * petal.factor - cr)
                    let fgPath = buildSector(outer: fgOuter, inner: rigidInner, h: h, sweepHalf: sweepHalf)
                    c.fill(fgPath, with: .color(fg))
                    c.stroke(fgPath, with: .color(fg), style: StrokeStyle(lineWidth: cr * 2, lineJoin: .round))
                }

                let textR = (innerR + outerR) / 2
                var tc = c
                tc.translateBy(x: textR, y: 0)
                tc.rotate(by: .radians(Double(-segAngle)))
                tc.draw(
                    Text("\(petal.value)").font(.system(size: 18 * scale, weight: .bold)).foregroundColor(.white),
                    at: CGPoint(x: 0, y: -9 * scale), anchor: .center
                )
                tc.draw(
                    Text(petal.label).font(.system(size: 9 * scale)).foregroundColor(.white.opacity(0.647)),
                    at: CGPoint(x: 0, y: 11 * scale), anchor: .center
                )

                startAngle += sweep
            }
        }
    }
}

/// Фолбэк лепесткового циферблата для iOS 14 (без Canvas): тёмный круг с
/// шестью значениями. Полный циферблат доступен на iOS 15+.
struct PetalDialFallback: View {
    let petals: [PetalInfo]
    let bg: Color
    let fg: Color

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(bg)
                VStack(spacing: 4) {
                    row(0, 1, 2)
                    row(3, 4, 5)
                }
                .padding(d * 0.12)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ a: Int, _ b: Int, _ c: Int) -> some View {
        HStack(spacing: 6) {
            cell(a); cell(b); cell(c)
        }
    }

    private func cell(_ i: Int) -> some View {
        let p = i < petals.count ? petals[i] : PetalInfo(value: 0, label: "", factor: 0)
        return VStack(spacing: 1) {
            Text("\(p.value)").font(.system(size: 16, weight: .bold)).foregroundColor(fg)
            Text(p.label).font(.system(size: 9)).foregroundColor(.white.opacity(0.647))
        }
        .frame(maxWidth: .infinity)
    }
}
