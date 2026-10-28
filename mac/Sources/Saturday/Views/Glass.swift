import SwiftUI

/// Saturday's glossy look: Apple's Liquid Glass on macOS 26, and frosted material with the same
/// specular highlights on older systems.
extension View {
    /// A glass panel: frosted, with a bright rim along the top edge and a soft shadow.
    func glassSurface(cornerRadius: CGFloat, tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, shadow: shadow))
    }

    func glassCapsule(tint: Color? = nil, shadow: Bool = true) -> some View {
        modifier(GlassSurface(shape: Capsule(), tint: tint, shadow: shadow))
    }

    /// A lighter inset for things sitting on a glass panel (cards, fields, chips), since glass on glass looks muddy.
    func glassInset<S: InsettableShape>(_ shape: S, highlighted: Bool = false) -> some View {
        background(shape.fill(Color.white.opacity(highlighted ? 0.14 : 0.07)))
            .overlay(shape.strokeBorder(Gloss.rim(highlighted ? 0.55 : 0.32), lineWidth: 0.8))
    }
}

enum Gloss {
    /// Light catching the top edge and fading down the sides, like the rim of polished glass.
    static func rim(_ strength: Double = 0.5) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(strength), location: 0),
            .init(color: .white.opacity(strength * 0.18), location: 0.35),
            .init(color: .white.opacity(0.03), location: 0.7),
            .init(color: .white.opacity(strength * 0.3), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The soft sheen across the upper part of a glossy surface.
    static let sheen = LinearGradient(stops: [
        .init(color: .white.opacity(0.22), location: 0),
        .init(color: .white.opacity(0.06), location: 0.28),
        .init(color: .clear, location: 0.55),
    ], startPoint: .top, endPoint: .bottom)
}

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color?
    var shadow: Bool

    func body(content: Content) -> some View {
        content
            .background { base }
            .overlay { shape.strokeBorder(Gloss.rim(0.55), lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 30, y: 14)
            .shadow(color: .black.opacity(shadow ? 0.12 : 0), radius: 3, y: 1)
    }

    @ViewBuilder
    private var base: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(tint.map { SwiftUI.Glass.regular.tint($0.opacity(0.18)) } ?? .regular, in: shape)
                .overlay { shape.fill(Gloss.sheen).blendMode(.plusLighter).allowsHitTesting(false) }
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                if let tint { shape.fill(tint.opacity(0.08)) }
                shape.fill(Gloss.sheen).blendMode(.plusLighter)
            }
        }
    }
}

/// A shiny, candy-like round button: a colored gradient with a highlight across the top half.
struct GlossyCircle<Fill: ShapeStyle>: View {
    var fill: Fill
    var size: CGFloat
    var glow: Color = .pink

    var body: some View {
        ZStack {
            Circle().fill(fill)
            // The bright reflection across the top.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.72, height: size * 0.46)
                .offset(y: -size * 0.2)
                .blur(radius: 0.5)
            // A faint bounce of light along the bottom.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.28), .clear], center: .init(x: 0.5, y: 1.05), startRadius: 0, endRadius: size * 0.45))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        }
        .frame(width: size, height: size)
        .shadow(color: glow.opacity(0.45), radius: 8, y: 3)
    }
}

/// Slowly drifting color behind onboarding and setup, so the glass has something to refract.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let w = geometry.size.width, h = geometry.size.height
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    blob(.pink, x: w * (0.2 + 0.08 * sin(t * 0.3)), y: h * (0.15 + 0.05 * cos(t * 0.25)), size: w * 0.7)
                    blob(.purple, x: w * (0.85 + 0.06 * cos(t * 0.22)), y: h * (0.3 + 0.08 * sin(t * 0.27)), size: w * 0.65)
                    blob(.orange, x: w * (0.6 + 0.1 * sin(t * 0.18)), y: h * (0.95 + 0.04 * cos(t * 0.3)), size: w * 0.6)
                    blob(.cyan, x: w * (0.1 + 0.05 * cos(t * 0.2)), y: h * (0.85 + 0.05 * sin(t * 0.23)), size: w * 0.5)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, x: CGFloat, y: CGFloat, size: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(0.32))
            .frame(width: size, height: size)
            .blur(radius: size * 0.28)
            .position(x: x, y: y)
    }
}
