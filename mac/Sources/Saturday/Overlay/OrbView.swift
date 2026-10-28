import SwiftUI

/// Saturday's living orb: layered color blobs that swirl, breathe, and react to the voice.
/// Calm when idle, quick swirl while thinking, pulsing with the mic or the voice when talking.
struct OrbView: View {
    var phase: Assistant.Phase
    var level: CGFloat
    var size: CGFloat = 150

    private static let palettes: [[Color]] = [
        [.pink, .orange, .yellow, .pink],
        [.purple, .blue, .cyan, .purple],
        [.orange, .red, .purple, .orange],
        [.cyan, .mint, .indigo, .cyan],
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // The colored light spilling around the marble.
                colors(t)
                    .blur(radius: 14)
                    .opacity(0.75)
                    .scaleEffect(1.08)
                // The marble: swirling color sealed inside polished glass.
                ZStack {
                    Circle().fill(Color.black.opacity(0.18))
                    colors(t)
                    // Depth: darker toward the rim, like light passing through a sphere.
                    Circle().fill(RadialGradient(colors: [.clear, .clear, .black.opacity(0.28)],
                                                 center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: 64))
                }
                .clipShape(Circle())
                .frame(width: 118, height: 118)
                // The bright window reflection across the top.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.78), .white.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 78, height: 46)
                    .offset(y: -33)
                    .blur(radius: 1.2)
                    .blendMode(.plusLighter)
                // A small sharp glint.
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 9, height: 9)
                    .offset(x: -26, y: -30)
                    .blur(radius: 1.5)
                // Light bouncing up from below and the polished rim.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: .init(x: 0.5, y: 1), startRadius: 0, endRadius: 40))
                    .frame(width: 118, height: 118)
                    .blendMode(.plusLighter)
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08), .white.opacity(0.4)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
                    .frame(width: 118, height: 118)
            }
            .scaleEffect(pulse(t))
            .compositingGroup()
        }
        .frame(width: 150, height: 150)
        .scaleEffect(size / 150)
        .frame(width: size, height: size)
        .accessibilityLabel("Saturday")
    }

    private func colors(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                blob(index, time: t)
            }
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 34))
                .frame(width: 70, height: 70)
                .blendMode(.plusLighter)
                .opacity(phase == .thinking ? 0.55 + 0.35 * sin(t * 5) : 0.7)
        }
    }

    private var speed: Double {
        switch phase {
        case .thinking: 2.8
        case .listening: 1.5
        case .responding: 1.2
        case .idle, .done: 0.5
        }
    }

    private func pulse(_ t: Double) -> CGFloat {
        let breathe = phase == .thinking ? 0.06 * sin(t * 7) : 0.035 * sin(t * 1.8)
        return 1 + level * 0.5 + CGFloat(breathe)
    }

    private func blob(_ index: Int, time t: Double) -> some View {
        let i = Double(index)
        let direction: Double = index.isMultiple(of: 2) ? 1 : -1
        let size = 100 - CGFloat(index) * 11
        let wobble = 7 + level * 14
        return Circle()
            .fill(AngularGradient(colors: Self.palettes[index], center: .center,
                                  angle: .radians(t * speed * (1 + i * 0.4) * direction)))
            .frame(width: size, height: size)
            .offset(x: cos(t * speed * (0.8 + i * 0.3) + i) * wobble,
                    y: sin(t * speed * (0.9 + i * 0.25) + i * 2) * wobble)
            .blur(radius: 10 + CGFloat(index) * 3)
            .opacity(0.9)
            .blendMode(.plusLighter)
    }
}

/// The rainbow light that runs down the right edge of the screen while Saturday is active.
struct EdgeGlow: View {
    var phase: Assistant.Phase
    var level: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let shift = (t * (phase == .thinking ? 0.6 : 0.2)).truncatingRemainder(dividingBy: 1)
            let colors = (0..<7).map { Color(hue: (Double($0) / 6 + shift).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 1) }
            let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            ZStack(alignment: .trailing) {
                Rectangle().fill(gradient).frame(width: 18 + level * 26).blur(radius: 16).opacity(0.8)
                Rectangle().fill(gradient).frame(width: 3)
            }
            .opacity(phase == .idle || phase == .done ? 0.45 : 1)
        }
        .allowsHitTesting(false)
    }
}

/// A ring of light that bursts outward from the orb when Saturday appears.
struct BurstRing: View {
    var trigger: UUID
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(AngularGradient(colors: [.pink, .orange, .yellow, .cyan, .purple, .pink], center: .center), lineWidth: 8)
            .frame(width: 110, height: 110)
            .scaleEffect(expanded ? 2.8 : 0.3)
            .opacity(expanded ? 0 : 1)
            .blur(radius: expanded ? 8 : 0)
            .allowsHitTesting(false)
            .onChange(of: trigger, initial: true) { _, _ in
                expanded = false
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 1.0)) { expanded = true }
                }
            }
    }
}
