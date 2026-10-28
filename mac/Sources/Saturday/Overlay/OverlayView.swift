import AppKit
import SwiftUI

@MainActor
final class OverlayState: ObservableObject {
    @Published var visible = false
    /// The panel's contents exist only while it's on screen, so its animations don't run in the background.
    @Published var mounted = false
    @Published var appearID = UUID()
}

/// The Siri-style panel on the right edge of the screen: context, orb, live transcript, answer card and composer.
struct OverlayView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject var assistant: Assistant
    @ObservedObject var listener: SpeechInput
    @ObservedObject var speaker: SpeechOutput
    @ObservedObject var live: LiveVoice
    var onClose: () -> Void
    var onOpenChat: () -> Void
    var onHover: (Bool) -> Void

    @State private var draft = ""
    /// Measured height of the answer text, so the card is exactly as tall as it needs to be.
    @State private var answerHeight: CGFloat = 0
    @FocusState private var typing: Bool

    private var level: CGFloat { max(listener.level, speaker.level, live.level) }
    /// Saturday is hearing the user (its own listener, or the live voice agent).
    private var hearing: Bool { listener.isListening || live.isActive }
    private var speaking: Bool { speaker.isSpeaking || live.isAssistantSpeaking }
    private var heardText: String { live.isActive ? live.userTranscript : listener.transcript }
    private var reply: ChatMessage? { assistant.currentReply }
    private var showsAnswer: Bool {
        guard let reply, !DisplayText.clean(reply.text).isEmpty else { return false }
        return live.isActive ? !live.isUserSpeaking : assistant.phase != .listening
    }

    var body: some View {
        if state.mounted { content }
    }

    private var content: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                EdgeGlow(phase: assistant.phase, level: level)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(state.visible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: state.visible)

                card(maxAnswerHeight: max(160, geometry.size.height - 330))
                    .padding(.top, 12)
                    .padding(.trailing, 26)
                    .offset(x: state.visible ? 0 : 520)
                    .scaleEffect(state.visible ? 1 : 0.9, anchor: .topTrailing)
                    .opacity(state.visible ? 1 : 0)
                    .blur(radius: state.visible ? 0 : 12)
                    .animation(.spring(response: 0.55, dampingFraction: 0.72), value: state.visible)
                    .onHover(perform: onHover)
            }
        }
        .onChange(of: state.appearID) { _, _ in
            draft = ""
            typing = false
        }
    }

    // MARK: - Card

    private func card(maxAnswerHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            hero
            if showsAnswer, let reply {
                answerCard(reply, maxHeight: maxAnswerHeight)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else if assistant.phase == .idle || (assistant.phase == .done && reply == nil) {
                suggestions.transition(.opacity)
            }
            composer
        }
        .padding(18)
        .frame(width: 420)
        .background {
            // A soft wash of the orb's color, under the glass.
            RadialGradient(colors: [Color.pink.opacity(0.16), Color.purple.opacity(0.07), .clear],
                           center: .top, startRadius: 10, endRadius: 320)
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .glassSurface(cornerRadius: 34, tint: .pink)
        .overlay {
            // A faint ribbon of Saturday's colors around the edge.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(AngularGradient(colors: Theme.spectrum.map { $0.opacity(0.4) }, center: .center), lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showsAnswer)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: assistant.phase)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = assistant.contextAppIcon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            if let app = assistant.contextAppName {
                Text(assistant.hasSelection ? "\(app) · selection" : app)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            iconButton("bubble.left.and.bubble.right", help: "Open the full conversation", action: onOpenChat)
            iconButton("xmark", help: "Close (Esc)", action: onClose)
        }
    }

    private var hero: some View {
        VStack(spacing: showsAnswer ? 4 : 10) {
            ZStack {
                BurstRing(trigger: state.appearID)
                OrbView(phase: assistant.phase, level: level, size: showsAnswer ? 72 : 132)
            }
            .frame(maxWidth: .infinity)

            VoiceBars(level: level, active: live.isActive ? (live.isUserSpeaking || live.isAssistantSpeaking) : (listener.isListening || speaker.isSpeaking))
                .frame(height: showsAnswer ? 16 : 30)
                .clipped()

            status
            transcript
        }
    }

    @ViewBuilder
    private var status: some View {
        switch assistant.phase {
        case .thinking:
            ShimmerText(text: assistant.status.isEmpty ? "Thinking…" : assistant.status)
        case .listening:
            Text(live.isActive ? (live.isUserSpeaking ? "Listening…" : "I'm listening. Just talk.") : listener.isListening ? "Listening…" : "Getting ready…")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.accent)
        case .responding, .done:
            Text(speaking ? "Speaking…" : assistant.phase == .done ? "Press ⌥ Space to follow up" : "Answering…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        case .idle:
            Text(assistant.status.isEmpty ? greeting : assistant.status)
                .font(Theme.rounded(20))
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if assistant.phase == .listening || (live.isActive && live.isUserSpeaking) {
            Text(heardText.isEmpty ? "Go ahead, I'm all ears." : heardText)
                .font(Theme.rounded(21))
                .foregroundStyle(heardText.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.15), value: heardText)
        } else if !assistant.currentQuestion.isEmpty, assistant.phase != .idle {
            Text(assistant.currentQuestion)
                .font(Theme.rounded(showsAnswer ? 15 : 17, .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(showsAnswer ? 2 : 3)
                .frame(maxWidth: .infinity)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Up late?" : hour < 12 ? "Good morning." : hour < 17 ? "Good afternoon." : "Good evening."
        return "\(part) What's up?"
    }

    // MARK: - Answer

    private func answerCard(_ reply: ChatMessage, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let tag = reply.engine {
                    TagChip(text: tag, symbol: TagChip.symbol(for: tag))
                }
                Spacer()
                if !reply.isError {
                    iconButton("doc.on.doc", help: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DisplayText.clean(reply.text), forType: .string)
                    }
                }
            }
            ScrollView(showsIndicators: answerHeight > maxHeight) {
                answer(reply)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: AnswerHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(answerHeight, 18), maxHeight))
            .onPreferenceChange(AnswerHeightKey.self) { answerHeight = $0 }
        }
        .padding(14)
        .glassInset(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func answer(_ reply: ChatMessage) -> some View {
        if reply.isError {
            Label { Text(.init(reply.text)) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownView(text: DisplayText.clean(reply.text))
        }
    }

    // MARK: - Suggestions and composer

    private var suggestionItems: [(String, String)] {
        if assistant.hasSelection {
            return [("Explain this", "lightbulb"), ("Summarize this", "text.alignleft"),
                    ("Make it sound better", "wand.and.stars"), ("Translate this", "globe")]
        }
        let app = assistant.contextAppName?.lowercased() ?? ""
        if ["safari", "google chrome", "arc", "firefox", "microsoft edge", "brave browser"].contains(app) {
            return [("Summarize this page", "doc.text.magnifyingglass"), ("What's on my screen?", "eye"),
                    ("What's the latest news?", "newspaper"), ("Plan my day", "calendar")]
        }
        return [("What's on my screen?", "eye"), ("What's the weather today?", "cloud.sun"),
                ("Plan my day", "calendar"), ("Tell me something cool", "sparkles")]
    }

    private var suggestions: some View {
        FlowLayout(spacing: 8) {
            ForEach(suggestionItems, id: \.0) { item in
                SuggestionChip(text: item.0, symbol: item.1) { assistant.send(item.0) }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button { assistant.toggleListening() } label: {
                    GlossyCircle(fill: hearing ? AnyShapeStyle(LinearGradient(colors: [.red, .pink], startPoint: .top, endPoint: .bottom))
                                               : AnyShapeStyle(Theme.accent),
                                 size: 34, glow: hearing ? .red : .pink)
                        .overlay {
                            Image(systemName: hearing ? "waveform" : "mic.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                                .symbolEffect(.variableColor.iterative, isActive: hearing)
                        }
                }
                .buttonStyle(.plain)
                .help(live.isActive ? "End the conversation" : listener.isListening ? "Done talking" : "Talk")

                TextField("Ask Saturday anything…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($typing)
                    .onSubmit(sendDraft)
                    .onChange(of: draft) { _, value in
                        if !value.isEmpty, listener.isListening { listener.stop(send: false) }
                    }

                if assistant.isWorking || speaking {
                    Button(action: assistant.stop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .glassInset(Circle(), highlighted: true)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else if !draft.isEmpty {
                    Button(action: sendDraft) {
                        GlossyCircle(fill: Theme.accent, size: 28)
                            .overlay {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassInset(Capsule(), highlighted: typing)
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1).opacity(typing ? 0.8 : 0).allowsHitTesting(false))
            .animation(.easeOut(duration: 0.15), value: draft.isEmpty)

            // OpenAI asks apps to say when a reply used the person's ChatGPT plan; shown only then.
            if reply?.usedPlan == true {
                HStack(spacing: 4) {
                    Text("Used your ChatGPT plan ·")
                    Link("Manage usage", destination: ChatGPTAccount.usageURL)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        assistant.send(text)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .glassInset(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
