import AppKit
import SwiftUI

enum Theme {
    static let spectrum: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .indigo, .purple, .pink]
    static let accent = LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cool = LinearGradient(colors: [.cyan, .indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Live audio bars under the orb: they dance with your voice while listening and with Saturday's while speaking.
struct VoiceBars: View {
    var level: CGFloat
    var active: Bool
    var bars = 28

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(LinearGradient(colors: [.pink, .orange, .cyan], startPoint: .bottom, endPoint: .top))
                        .frame(width: 3, height: height(index, t))
                }
            }
            .frame(height: 44)
            .opacity(active ? 1 : 0.25)
        }
        .animation(.easeOut(duration: 0.25), value: active)
    }

    private func height(_ index: Int, _ t: Double) -> CGFloat {
        guard active else { return 3 }
        let i = Double(index)
        let center = 1 - abs(i - Double(bars) / 2) / (Double(bars) / 2)
        let wave = abs(sin(t * 7 + i * 0.55)) * 0.6 + abs(sin(t * 3.1 + i * 1.3)) * 0.4
        return 3 + CGFloat(wave * (0.35 + center * 0.65)) * (8 + level * 36)
    }
}

/// Text with a moving shine, used for "Thinking…".
struct ShimmerText: View {
    var text: String
    var font: Font = .callout.weight(.medium)

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, phase - 0.25)),
                            .init(color: .white.opacity(0.9), location: phase),
                            .init(color: .clear, location: min(1, phase + 0.25)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .mask(Text(text).font(font))
                    .blendMode(.plusLighter)
                }
        }
    }
}

/// A small rounded tag such as "Searched the web".
struct TagChip: View {
    var text: String
    var symbol: String = "sparkle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassInset(Capsule())
    }

    static func symbol(for tag: String) -> String {
        switch tag {
        case "Searched the web": "globe"
        case "Quick answer": "bolt.fill"
        case "Deep thinking", "Deep Think": "brain"
        case "Creative": "paintbrush.pointed.fill"
        case "Looked at your screen": "eye.fill"
        case "Read your selection": "text.quote"
        case "Done on your Mac": "checkmark.circle.fill"
        default: "sparkle"
        }
    }
}

/// A suggestion button shown when Saturday is waiting.
struct SuggestionChip: View {
    var text: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassInset(Capsule(), highlighted: hovering)
                .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Cards for choosing Saturday's personality. Selecting one plays a sample in that voice.
struct PersonalityPicker: View {
    @ObservedObject var settings: SettingsStore
    var preview: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(VoicePersonality.allCases) { personality in
                let selected = settings.voicePersonality == personality
                Button {
                    settings.voicePersonality = personality
                    settings.geminiVoice = personality.suggestedVoice
                    preview()
                } label: {
                    HStack(spacing: 10) {
                        GlossyCircle(fill: selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.45)),
                                     size: 36, glow: selected ? .pink : .clear)
                            .overlay {
                                Image(systemName: personality.symbol)
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(personality.label).font(Theme.rounded(14))
                            Text(personality.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if selected { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassInset(RoundedRectangle(cornerRadius: 14, style: .continuous), highlighted: selected)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 1.5)
                            .opacity(selected ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Key caps, e.g. ⌥ + Space, for showing the shortcut.
struct KeyCaps: View {
    var keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 { Text("+").foregroundStyle(.secondary) }
                Text(key)
                    .font(Theme.rounded(15, .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassInset(RoundedRectangle(cornerRadius: 8, style: .continuous), highlighted: true)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
        }
    }
}
