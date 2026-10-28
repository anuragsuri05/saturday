import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var account: ChatGPTAccount
    @ObservedObject var memory: MemoryStore
    var testVoice: () -> Void
    var retryLivePlan: () -> Void = {}

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "sparkles") }
            VoiceTab(settings: settings, testVoice: testVoice, retryLivePlan: retryLivePlan)
                .tabItem { Label("Voice", systemImage: "waveform") }
            AccessTab(settings: settings)
                .tabItem { Label("Access", systemImage: "lock.open") }
            AccountsTab(settings: settings, account: account)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            MemoryTab(memory: memory)
                .tabItem { Label("Memory", systemImage: "brain") }
            AdvancedTab(settings: settings, account: account)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 600)
    }
}

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Summon Saturday") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyCaps(keys: ["⌥", "Space"])
                }
                Picker("Extra shortcut", selection: $settings.extraTrigger) {
                    ForEach(ExtraTrigger.allCases) { Text($0.label).tag($0) }
                }
                if settings.extraTrigger != .none {
                    PermissionRow(title: "Accessibility access", granted: ContextReader.hasAccessibility, refresh: $refresh) {
                        ContextReader.requestAccessibility()
                    }
                    if settings.extraTrigger == .doubleFn {
                        Note("Tip: in System Settings → Keyboard, set “Press 🌐 key to” Do Nothing, so Fn doesn't also open emoji or dictation.")
                    }
                }
                Toggle("Start listening as soon as Saturday appears", isOn: $settings.autoListen)
                Toggle("Keep my speech on this Mac (more private, less accurate)", isOn: $settings.privateSpeech)
                Toggle("Hide automatically after answering", isOn: $settings.autoHide)
            }

            Section {
                Picker("Thinking style", selection: $settings.mode) {
                    ForEach(Mode.everyday) { Text($0.label).tag($0) }
                    if !Mode.everyday.contains(settings.mode) { Text(settings.mode.label).tag(settings.mode) }
                }
                .pickerStyle(.segmented)
                Toggle("Genius mode for the hardest questions", isOn: $settings.geniusMode)
                Picker("Play music in", selection: $settings.musicApp) {
                    Text("Apple Music").tag("apple_music")
                    Text("Spotify").tag("spotify")
                    Text("YouTube Music").tag("youtube")
                }
                Toggle("Understand what's on my screen", isOn: $settings.useScreenContext)
            } header: {
                Text("Intelligence")
            } footer: {
                Note("Smart picks the best brain for each request in a split second. Deep Think consults several at once and merges the best answer: slower, but sharper. Genius mode uses the most powerful model for hard problems.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccessTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    PermissionsIntro(permissions: permissions)
                    PermissionList(permissions: permissions, compact: true)
                }
                .padding(.vertical, 8)
            }
            Section {
                Toggle("Ask before sending, deleting, buying or running shell commands", isOn: $settings.askBeforeRisky)
            } footer: {
                Note("Saturday clicks, types and controls apps without interrupting you. With this on, it still checks with you before anything that's hard to undo.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var offline = LocalVoice.shared
    var testVoice: () -> Void
    var retryLivePlan: () -> Void

    var body: some View {
        Form {
            Section("Personality") {
                PersonalityPicker(settings: settings, preview: testVoice)
                    .padding(.vertical, 4)
            }

            Section {
                OfflineVoiceRow(settings: settings, offline: offline, testVoice: testVoice)
            } header: {
                Text("Free natural voice")
            } footer: {
                Note("An open-source neural voice that runs right on your Mac: free, private, and it works offline. One-time download of \(settings.localModel.downloadSize).")
            }

            Section {
                Picker("Voice quality", selection: $settings.voiceEngine) {
                    ForEach(VoiceEngine.allCases) { Text($0.label).tag($0) }
                }
                if settings.voiceEngine == .gptLive {
                    Picker("GPT-Live voice", selection: $settings.liveVoice) {
                        ForEach(LiveVoice.voices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    if settings.openAIKey.isEmpty {
                        switch settings.livePlanAccepted {
                        case true?:
                            Label("Using your ChatGPT login for the voice", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case false?:
                            Label("OpenAI didn't allow the ChatGPT login for voice", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                            Note("OpenAI said: \(settings.livePlanReason). Add an OpenAI API key below to use the GPT voice, or pick another voice.")
                        case nil:
                            Note(ChatGPTAccount.shared.planEnabled ? "Checking whether your ChatGPT login can power the voice…" : "Sign in with ChatGPT (Accounts) or add an OpenAI API key.")
                        }
                        if ChatGPTAccount.shared.planEnabled {
                            Button("Try the ChatGPT login again", action: retryLivePlan)
                        }
                    }
                    KeyField(title: "OpenAI API key", text: $settings.openAIKey, isSet: !settings.openAIKey.isEmpty,
                             link: "https://platform.openai.com/api-keys", linkTitle: "Get key")
                    Note("A real back-and-forth conversation: Saturday listens while it talks, so you can interrupt it like a person. Your other accounts still do the thinking. With an API key, OpenAI bills about 5 cents per minute; Saturday hangs up after 25 seconds of silence.")
                }
                if settings.voiceEngine == .gemini || (settings.voiceEngine == .auto && settings.elevenLabsKey.isEmpty) {
                    HStack {
                        Picker("Voice", selection: $settings.geminiVoice) {
                            ForEach(GeminiTTS.voices, id: \.name) { Text("\($0.name) · \($0.style)").tag($0.name) }
                        }
                        Button(action: testVoice) { Image(systemName: "play.circle.fill").font(.title3) }
                            .buttonStyle(.borderless)
                            .help("Play a sample")
                    }
                    if !settings.isAvailable(.gemini) {
                        Note("The studio voice needs a free Gemini key (Settings → Accounts). Until then Saturday uses the offline voice.")
                    }
                }
                if settings.voiceEngine == .elevenLabs || (settings.voiceEngine == .auto && !settings.elevenLabsKey.isEmpty) {
                    Picker("Voice model", selection: $settings.elevenModel) {
                        ForEach(ElevenLabsLive.models, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    HStack {
                        Picker("Voice", selection: $settings.elevenVoiceID) {
                            ForEach(ElevenLabsLive.voices, id: \.id) { Text($0.name).tag($0.id) }
                            if !ElevenLabsLive.voices.contains(where: { $0.id == settings.elevenVoiceID }) {
                                Text("Custom voice").tag(settings.elevenVoiceID)
                            }
                        }
                        Button(action: testVoice) { Image(systemName: "play.circle.fill").font(.title3) }
                            .buttonStyle(.borderless)
                            .help("Play a sample")
                    }
                    TextField("Or paste any voice ID", text: $settings.elevenVoiceID)
                    if settings.elevenLabsKey.isEmpty {
                        Note("Add your ElevenLabs key in Accounts. Until then Saturday uses the studio or offline voice.")
                    } else {
                        Note("Saturday streams each reply as one continuous performance, so it flows like a real person talking.")
                    }
                }
                Toggle("Conversation mode: keep listening after I answer", isOn: $settings.conversationMode)
                Toggle("Read the full answer aloud (not just the summary)", isOn: $settings.speakFullAnswer)
                Toggle("Also speak replies to typed requests", isOn: $settings.speakReplies)
                HStack {
                    Button("Play sample", action: testVoice)
                    if !SpeechOutput.hasNaturalAppleVoice {
                        Button("Get a better offline voice") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
                        }
                        .buttonStyle(.link)
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Note("Saturday starts talking as soon as the first sentence is ready. For the offline voice, download a Premium voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var account: ChatGPTAccount

    var body: some View {
        Form {
            Section {
                if account.isSignedIn {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                            Text(account.planEnabled ? "Connected" : "Plan sharing isn't enabled yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("Manage usage", destination: ChatGPTAccount.usageURL).font(.callout)
                        Button("Sign out") { Task { await account.signOut() } }
                    }
                    if !account.planEnabled {
                        Button("Enable plan sharing") { Task { await account.signIn(forceConsent: true) } }
                    }
                } else {
                    HStack(spacing: 12) {
                        ContinueWithChatGPTButton(account: account)
                        if account.isSigningIn {
                            Button("Cancel", action: account.cancelSignIn).buttonStyle(.link)
                        } else if account.hasSavedRegistration {
                            Button("Use a different account") { Task { await account.forgetAccount() } }.buttonStyle(.link)
                        }
                    }
                    DisclosureGroup("Use an OpenAI API key instead") {
                        KeyField(title: "OpenAI API key", text: $settings.openAIKey, isSet: !settings.openAIKey.isEmpty,
                                 link: "https://platform.openai.com/api-keys", linkTitle: "Get key")
                    }
                }
                if let error = account.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("ChatGPT account")
            } footer: {
                Note("Sign in with your Plus or Pro plan. No API key needed.")
            }

            Section {
                KeyField(title: "Claude API key", text: $settings.anthropicKey, isSet: settings.isAvailable(.claude),
                         link: "https://console.anthropic.com/settings/keys", linkTitle: "Get key")
            } header: {
                Text("Claude")
            } footer: {
                Note("Anthropic only allows Claude Pro/Max sign-in inside its own apps, so Claude uses an API key. It makes Saturday strongest at actions, coding and reasoning.")
            }

            Section {
                KeyField(title: "Gemini API key", text: $settings.geminiKey, isSet: settings.isAvailable(.gemini),
                         link: "https://aistudio.google.com/apikey", linkTitle: "Get free key")
            } header: {
                Text("Gemini")
            } footer: {
                Note("Free from Google AI Studio. It unlocks Saturday's natural studio voice and live web answers.")
            }

            Section {
                TextField("Spotify Client ID", text: $settings.spotifyClientID)
                SecureField("Spotify Client Secret", text: $settings.spotifyClientSecret)
                Link("Create a free Spotify app", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.caption)
            } header: {
                Text("Spotify (optional)")
            } footer: {
                Note("Lets Saturday start the exact song by itself. On the Spotify developer dashboard, click Create app, give it any name, add http://127.0.0.1:8888/callback as the redirect URI, tick Web API, save, then copy the Client ID and Client secret here. Without this, Saturday opens Spotify with your song at the top, ready to play.")
            }

            Section {
                KeyField(title: "ElevenLabs API key", text: $settings.elevenLabsKey, isSet: !settings.elevenLabsKey.isEmpty,
                         link: "https://elevenlabs.io/app/settings/api-keys", linkTitle: "Get key")
            } header: {
                Text("ElevenLabs (optional)")
            } footer: {
                Note("For the most lifelike voice. Saturday uses it automatically once a key is added.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MemoryTab: View {
    @ObservedObject var memory: MemoryStore
    @State private var newMemory = ""

    var body: some View {
        Form {
            Section {
                if memory.items.isEmpty {
                    Note("Nothing yet. Saturday learns as you talk, or say “remember that I'm vegetarian”.")
                }
                ForEach(memory.items) { item in
                    HStack {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent)
                        Text(item.text)
                        Spacer()
                        Button { memory.remove(item) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Forget this")
                    }
                }
                HStack {
                    TextField("Add something Saturday should know about you", text: $newMemory)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !memory.items.isEmpty {
                    Button("Forget everything", role: .destructive, action: memory.clear)
                }
            } header: {
                Text("What Saturday knows about you")
            } footer: {
                Note("Stored only on this Mac and used to personalize every answer.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        memory.add(newMemory)
        newMemory = ""
    }
}

private struct AdvancedTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var account: ChatGPTAccount

    var body: some View {
        Form {
            Section {
                Picker("Brain", selection: $settings.mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Routing")
            } footer: {
                Note("Smart is recommended. The single-service options force every request to one account.")
            }
            Section("Models") {
                if account.planEnabled && !account.models.isEmpty {
                    Picker("OpenAI", selection: $settings.openAIModel) {
                        ForEach(account.models) { Text($0.name).tag($0.slug) }
                    }
                } else {
                    TextField("OpenAI", text: $settings.openAIModel)
                }
                TextField("Claude (main)", text: $settings.claudeModel)
                TextField("Claude (quick answers)", text: $settings.claudeFastModel)
                TextField("Claude (genius mode)", text: $settings.claudeGeniusModel)
                TextField("Gemini", text: $settings.geminiModel)
                TextField("Gemini (quick answers)", text: $settings.geminiFastModel)
                TextField("Gemini voice model", text: $settings.geminiTTSModel)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared pieces

struct KeyField: View {
    var title: String
    @Binding var text: String
    var isSet: Bool
    var link: String
    var linkTitle: String

    var body: some View {
        HStack {
            Image(systemName: isSet ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSet ? Color.green : Color.secondary)
            SecureField(title, text: $text)
            Button("Paste") {
                text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            Link(linkTitle, destination: URL(string: link)!).font(.caption)
        }
    }
}

struct PermissionRow: View {
    var title: String
    var granted: Bool
    @Binding var refresh: Int
    var request: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            if !granted {
                Button("Allow") {
                    request()
                    refresh += 1
                }
            }
        }
        .id(refresh)
    }
}

struct Note: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

struct ContinueWithChatGPTButton: View {
    @ObservedObject var account: ChatGPTAccount

    var body: some View {
        Button {
            Task { await account.signIn() }
        } label: {
            HStack(spacing: 8) {
                if account.isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                }
                Text(account.isSigningIn ? "Finish signing in in your browser…" : "Continue with ChatGPT")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(account.isSigningIn)
    }
}

/// Download, choose and preview the free on-device voice.
private struct OfflineVoiceRow: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var offline: LocalVoice
    var testVoice: () -> Void

    var body: some View {
        Picker("Voice model", selection: $settings.localModel) {
            ForEach(NeuralVoiceModel.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: settings.localModel) { _, model in
            offline.refresh()
            NeuralVoiceEngine.shared.prewarm(model)
        }
        if settings.localModel != NeuralVoiceModel.recommended {
            Note(NeuralVoiceModel.recommended == .supertonic
                 ? "On this Mac, Supertonic is recommended: Kokoro can't speak as fast as real time here."
                 : "On this Mac, Kokoro is recommended for the most natural sound.")
        }
        state
    }

    @ViewBuilder
    private var state: some View {
        switch offline.state {
        case .ready:
            HStack {
                Picker("Voice", selection: settings.localModel == .kokoro ? $settings.kokoroSpeaker : $settings.supertonicSpeaker) {
                    ForEach(settings.localModel.voices, id: \.id) { Text($0.label).tag(Int($0.id)) }
                }
                Button(action: testVoice) { Image(systemName: "play.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .help("Play a sample")
            }
            HStack {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Button("Remove", role: .destructive, action: offline.remove).buttonStyle(.borderless)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress) {
                    Text("Downloading the voice… \(Int(progress * 100))%")
                }
                Button("Cancel", action: offline.cancelInstall).buttonStyle(.link)
            }
        case .installing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Setting up the voice…")
            }
        case .notInstalled:
            HStack {
                Text("Give Saturday a human-like voice for free.")
                Spacer()
                Button("Download voice", action: offline.install).buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Try again", action: offline.install)
            }
        }
    }
}
