import AppKit
import SwiftUI

struct ChatView: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var settings: SettingsStore
    @ObservedObject var listener: SpeechInput
    @ObservedObject var account: ChatGPTAccount
    var openSettings: () -> Void
    @FocusState private var inputFocused: Bool

    private let suggestions: [(String, String)] = [
        ("What's the biggest tech news today?", "newspaper"),
        ("Open Safari and go to apple.com", "safari"),
        ("Explain async/await in Swift with an example", "chevron.left.forwardslash.chevron.right"),
        ("Brainstorm names for a weekend coffee pop-up", "lightbulb"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if assistant.messages.isEmpty { emptyState } else { transcript }
            inputBar
        }
        .frame(minWidth: 480, minHeight: 440)
        .background {
            ZStack {
                AuroraBackground().opacity(0.6)
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Gloss.sheen.opacity(0.6)).blendMode(.plusLighter)
            }
            .ignoresSafeArea()
        }
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OrbView(phase: assistant.isWorking ? .thinking : .idle, level: 0, size: 26)
            Text("Saturday").font(Theme.rounded(17, .bold))
            Spacer()
            Picker("Thinking style", selection: $settings.mode) {
                ForEach(Mode.everyday) { Text($0.label).tag($0) }
                if !Mode.everyday.contains(settings.mode) { Text(settings.mode.label).tag(settings.mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            .help("Smart picks the best brain for each request. Deep Think consults several and merges the best answer.")
            Button(action: assistant.newChat) { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New chat (⌘N)")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
        }
        .padding(.leading, 76)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            OrbView(phase: .idle, level: 0, size: 110)
            Text("Hi, I'm Saturday.").font(Theme.rounded(30, .bold))
            Text("Press ⌥ Space in any app and just talk, or type below.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !settings.hasAnyProvider {
                VStack(spacing: 10) {
                    ContinueWithChatGPTButton(account: account)
                    if let error = account.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    Button("More accounts…", action: openSettings).buttonStyle(.link)
                }
                .padding(.top, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(suggestions, id: \.0) { suggestion in
                        SuggestionChip(text: suggestion.0, symbol: suggestion.1) { assistant.send(suggestion.0) }
                    }
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(assistant.messages) { MessageRow(message: $0).id($0.id) }
                    if !assistant.status.isEmpty {
                        HStack(spacing: 8) {
                            if assistant.isWorking { ProgressView().controlSize(.small) }
                            Text(assistant.status).font(.callout).foregroundStyle(.secondary)
                        }
                        .id("status")
                    }
                }
                .padding(16)
            }
            .onChange(of: assistant.messages.last?.text) { _, _ in
                if let id = assistant.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = assistant.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button(action: assistant.toggleListening) {
                Image(systemName: listener.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(listener.isListening ? Color.red : Color.accentColor)
                    .symbolEffect(.pulse, isActive: listener.isListening)
            }
            .buttonStyle(.plain)
            .help(listener.isListening ? "Stop listening" : "Talk to Saturday")

            TextField(
                listener.isListening ? "Listening…" : "Ask Saturday anything…",
                text: listener.isListening ? .constant(listener.transcript) : $assistant.input,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .focused($inputFocused)
            .onSubmit { assistant.send() }
            .padding(.vertical, 4)

            if assistant.isWorking {
                Button(action: assistant.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button { assistant.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(assistant.input.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(assistant.input.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send (Return)")
            }
        }
        .padding(10)
        .glassSurface(cornerRadius: 18, shadow: false)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, usedPlan ? 4 : 12)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // OpenAI asks apps to say when a reply used the person's ChatGPT plan; shown only then.
            if usedPlan {
                HStack(spacing: 4) {
                    Text("Used your ChatGPT plan ·")
                    Link("Manage usage", destination: ChatGPTAccount.usageURL)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            }
        }
    }

    private var usedPlan: Bool {
        assistant.messages.last(where: { $0.role == .assistant })?.usedPlan == true
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accent)
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Gloss.sheen).blendMode(.plusLighter)
                            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Gloss.rim(0.6), lineWidth: 0.8)
                        }
                        .shadow(color: .pink.opacity(0.3), radius: 6, y: 3)
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let tag = message.engine {
                    TagChip(text: tag, symbol: TagChip.symbol(for: tag))
                }
                if message.isError || message.text.isEmpty {
                    Text(.init(message.text.isEmpty ? "…" : message.text))
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownView(text: DisplayText.clean(message.text))
                }
                if !message.text.isEmpty && !message.isError {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DisplayText.clean(message.text), forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
