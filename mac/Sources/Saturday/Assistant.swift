import AppKit
import Combine
import Foundation
import os

/// Runs the conversation: listens, routes each request, streams the reply to the screen and the voice
/// at the same time, learns about the user, and falls back to another model on failure.
@MainActor
final class Assistant: ObservableObject {
    enum Phase { case idle, listening, thinking, responding, done }

    @Published var messages: [ChatMessage] = History.load()
    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published var status = ""
    @Published private(set) var currentReplyID: UUID?
    @Published private(set) var currentQuestion = ""

    let settings = SettingsStore.shared
    let memory = MemoryStore.shared
    let listener = SpeechInput()
    let speaker = SpeechOutput()
    let live = LiveVoice()

    private var task: Task<Void, Never>?
    /// Called with the finished reply (used to hand results back to the live voice agent).
    private var turnCompletion: ((ChatMessage) -> Void)?
    // Live voice turn tracking.
    private var liveUserText = ""
    private var liveUserMessageID: UUID?
    private var liveReplyID: UUID?
    private var liveTurnDelegated = false
    private var liveTurnOpen = false
    private var context = ScreenContext()
    private var speakingThisTurn = false
    /// This turn was spoken, so Saturday may listen for a follow-up once it has finished talking.
    private var followUpEligible = false
    private var awaitingFollowUp = false
    private var cancellables = Set<AnyCancellable>()

    var isWorking: Bool { phase == .thinking || phase == .responding }
    var currentReply: ChatMessage? { currentReplyID.flatMap { id in messages.first { $0.id == id } } }
    var contextAppName: String? { context.appName }
    var contextAppIcon: NSImage? { context.appIcon }
    var hasSelection: Bool { context.selectedText != nil }

    init() {
        listener.onFinished = { [weak self] text, alternatives in self?.send(text, viaVoice: true, alsoHeard: alternatives) }
        listener.onCancelled = { [weak self] in
            if self?.phase == .listening { self?.phase = .idle }
        }
        listener.onError = { [weak self] message in
            self?.status = message
            self?.phase = .idle
        }
        speaker.$isSpeaking
            .removeDuplicates()
            .sink { [weak self] speaking in
                if !speaking { self?.listenForFollowUp() }
            }
            .store(in: &cancellables)
        setUpLiveVoice()
    }

    // MARK: - Live voice agent (GPT-Live)

    var liveActive: Bool { live.isActive }

    private func setUpLiveVoice() {
        live.onStarted = { [weak self] in
            self?.status = ""
            self?.phase = .listening
        }
        live.onUserText = { [weak self] delta in self?.liveHeard(delta) }
        live.onAssistantText = { [weak self] delta in self?.liveSaid(delta) }
        live.onDelegation = { [weak self] id in self?.liveDelegated(id) }
        live.onError = { [weak self] message in
            guard let self else { return }
            self.status = message
            if !self.live.isActive { self.phase = .idle }
        }
        live.onEnded = { [weak self] in
            guard let self else { return }
            self.closeLiveTurn()
            if !self.isWorking { self.phase = self.currentReply == nil ? .idle : .done }
            History.save(self.messages)
        }
        live.$isAssistantSpeaking
            .removeDuplicates()
            .sink { [weak self] speaking in
                guard let self, self.live.isActive else { return }
                if speaking {
                    if self.phase != .thinking { self.phase = .responding }
                } else if !self.isWorkingOnDelegation {
                    self.phase = .listening
                }
            }
            .store(in: &cancellables)
    }

    private var isWorkingOnDelegation: Bool { task != nil && phase == .thinking }

    /// Opens a full-duplex conversation with GPT-Live, primed with Saturday's personality, memory and context.
    private func startLive() {
        cancelWork()
        speaker.stop()
        status = "Connecting…"
        phase = .listening
        closeLiveTurn()
        if let chime = NSSound(named: NSSound.Name("Tink")) {
            chime.volume = 0.8
            chime.play()
        }
        let instructions = Prompts.live(personality: settings.voicePersonality, memories: memory.items, context: context)
        let history = turns()
        Task {
            // An OpenAI API key if there is one, otherwise the logged-in ChatGPT account.
            var bearer = settings.key(for: .openai)
            if bearer.isEmpty {
                do {
                    bearer = try await ChatGPTAccount.currentAccessToken()
                } catch {
                    status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    phase = .idle
                    return
                }
            }
            await live.start(apiKey: bearer, instructions: instructions, history: history, voice: settings.liveVoice)
        }
    }

    /// Checks once whether OpenAI lets the ChatGPT login drive GPT-Live, and remembers the answer.
    func checkLiveVoiceWithChatGPT(force: Bool = false) async {
        guard settings.key(for: .openai).isEmpty, ChatGPTAccount.shared.planEnabled else { return }
        guard force || settings.livePlanAccepted == nil else { return }
        guard let token = try? await ChatGPTAccount.currentAccessToken() else { return }
        let result = await LiveVoice.probe(bearer: token)
        switch result {
        case .accepted:
            settings.livePlanAccepted = true
            settings.livePlanReason = ""
            Self.log.notice("GPT-Live with ChatGPT login: accepted")
        case .rejected(var reason):
            // Make sure the login itself is fine: the same token should still work for text.
            var check = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            check.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: check), let http = response as? HTTPURLResponse {
                reason += http.statusCode == 200
                    ? " (your ChatGPT login is valid and works for text, but OpenAI doesn't accept it for the voice agent)"
                    : " (the login also failed for text with HTTP \(http.statusCode); try signing in again)"
            }
            settings.livePlanAccepted = false
            settings.livePlanReason = reason
            Self.log.notice("GPT-Live with ChatGPT login: rejected (\(reason, privacy: .public))")
        }
    }

    private static let log = Logger(subsystem: "com.saturday.assistant", category: "live-voice")

    /// The user is talking: start a new turn if Saturday spoke last.
    private func liveHeard(_ delta: String) {
        if !liveTurnOpen {
            closeLiveTurn()
            liveTurnOpen = true
        }
        liveUserText += delta
        if phase != .thinking { phase = .listening }
    }

    /// GPT-Live is answering by itself (small talk), so show what it says.
    private func liveSaid(_ delta: String) {
        liveTurnOpen = false
        guard !liveTurnDelegated else { return }
        if liveReplyID == nil {
            let question = liveUserText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                let user = ChatMessage(role: .user, text: question)
                messages.append(user)
                liveUserMessageID = user.id
                currentQuestion = question
            }
            let reply = ChatMessage(role: .assistant, text: "", engine: "Saturday")
            messages.append(reply)
            liveReplyID = reply.id
            currentReplyID = reply.id
        }
        if let id = liveReplyID { update(id) { $0.text += delta } }
    }

    /// GPT-Live handed a task to Saturday's brain: work out the request from the transcript and run it.
    private func liveDelegated(_ delegationID: String) {
        liveTurnDelegated = true
        live.setBusy(true)
        // Give the last transcript fragment a moment to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Drop the spoken acknowledgment ("one sec…") so the card shows the real answer.
            for id in [self.liveReplyID, self.liveUserMessageID].compactMap({ $0 }) {
                self.messages.removeAll { $0.id == id }
            }
            self.liveReplyID = nil
            self.liveUserMessageID = nil
            var request = self.liveUserText.trimmingCharacters(in: .whitespacesAndNewlines)
            if request.isEmpty { request = self.messages.last(where: { $0.role == .user })?.text ?? "" }
            guard !request.isEmpty else {
                self.live.deliver("I didn't catch the request. Ask the user to say it again.", delegationID: delegationID)
                self.live.setBusy(false)
                return
            }
            self.send(request, viaVoice: true, forLiveVoice: true) { [weak self] reply in
                guard let self else { return }
                let answer = DisplayText.clean(reply.text)
                let spoken = reply.isError ? "Something went wrong: \(answer)" : Self.spokenPart(of: answer)
                self.live.deliver(spoken, delegationID: delegationID)
                self.live.setBusy(false)
            }
        }
    }

    private func closeLiveTurn() {
        liveUserText = ""
        liveUserMessageID = nil
        liveReplyID = nil
        liveTurnDelegated = false
        liveTurnOpen = false
    }

    /// The part of a written answer worth saying aloud: the opening, plus a little detail if it's short.
    private static func spokenPart(of answer: String) -> String {
        let paragraphs = answer.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = paragraphs.first else { return answer }
        var spoken = first
        if paragraphs.count > 1 {
            let rest = paragraphs.dropFirst().joined(separator: "\n")
            spoken += rest.count < 500 ? "\n" + rest : "\n(More details are shown on screen.) " + String(rest.prefix(500))
        }
        return String(spoken.prefix(1500))
    }

    /// Conversation mode: once Saturday stops talking, listen for the user's reply, like a person would.
    private func listenForFollowUp() {
        guard awaitingFollowUp, phase == .done, settings.conversationMode else { return }
        awaitingFollowUp = false
        // A short beat so the end of Saturday's voice isn't picked up by the microphone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.phase == .done, !self.speaker.isSpeaking else { return }
            self.startListening(followUp: true)
        }
    }

    // MARK: - Summoning

    /// Called right before Saturday appears: remembers what the user was doing and warms up connections.
    func captureContext() {
        context = ContextReader.capture()
        Prewarm.run(settings)
    }

    func startListening(followUp: Bool = false) {
        if settings.usesLiveVoice {
            if !live.isActive { startLive() }
            return
        }
        cancelWork()
        speaker.stop()
        awaitingFollowUp = false
        status = ""
        phase = .listening
        if let chime = NSSound(named: NSSound.Name(followUp ? "Pop" : "Tink")) {
            chime.volume = followUp ? 0.35 : 0.8
            chime.play()
        }
        // A follow-up only waits a few seconds for the user to start talking.
        Task { await listener.start(waitForSpeech: followUp ? 5 : 7) }
    }

    func toggleListening() {
        if live.isActive {
            live.close()
        } else if listener.isListening {
            listener.stop(send: true)
        } else {
            startListening()
        }
    }

    /// The shortcut was pressed while Saturday is showing: finish listening, or listen again (barge-in).
    func triggerAgain() {
        if live.isActive {
            live.yieldToUser()
        } else if listener.isListening {
            listener.stop(send: true)
        } else {
            startListening()
        }
    }

    /// Saturday was hidden: stop listening and talking. Work in progress still finishes into the chat history.
    func dismissed() {
        awaitingFollowUp = false
        followUpEligible = false
        live.close()
        listener.stop(send: false)
        speaker.stop()
        speakingThisTurn = false
        if phase == .listening { phase = .idle }
    }

    // MARK: - Sending

    /// Runs one request through Saturday's brain. `forLiveVoice` means GPT-Live will speak the result,
    /// so Saturday's own voice stays quiet and `completion` receives the finished reply.
    func send(_ raw: String? = nil, viaVoice: Bool = false, alsoHeard: [String] = [], forLiveVoice: Bool = false,
              completion: ((ChatMessage) -> Void)? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelWork()
        turnCompletion = completion
        input = ""
        status = ""
        if listener.isListening { listener.stop(send: false) }

        let context = self.context
        let route = Router.route(text, mode: settings.mode, settings: settings, hasSelection: context.selectedText != nil)
        let history = turns()
        messages.append(ChatMessage(role: .user, text: text))
        currentQuestion = text

        guard route.kind == .local || settings.hasAnyProvider else {
            let reply = ChatMessage(role: .assistant, text: "Connect an account in **Settings → Accounts** and I'm ready.", engine: "Saturday", isError: true)
            messages.append(reply)
            currentReplyID = reply.id
            phase = .done
            turnCompletion?(reply)
            turnCompletion = nil
            return
        }

        let reply = ChatMessage(role: .assistant, text: "", engine: route.label)
        messages.append(reply)
        currentReplyID = reply.id
        phase = .thinking
        status = route.statusText
        speakingThisTurn = (viaVoice || settings.speakReplies) && !forLiveVoice && !live.isActive
        followUpEligible = viaVoice && route.kind != .local && !forLiveVoice
        awaitingFollowUp = false
        if speakingThisTurn { speaker.begin(summaryOnly: !settings.speakFullAnswer) }

        task = Task { [weak self] in
            guard let self else { return }
            var turn = Turn(role: .user, text: text)
            if route.kind != .local, self.settings.useScreenContext, context.selectedText == nil, Router.needsScreen(text) {
                self.status = "Looking at your screen…"
                if let screenshot = await ContextReader.screenshot() {
                    turn.images = [screenshot]
                } else {
                    Permissions.shared.showSetup()
                    turn = Turn(role: .user, text: text + "\n\n(Saturday couldn't capture the screen because Screen Recording permission is off. " +
                        "Tell the user in one short sentence to turn on Screen Recording for Saturday in the setup window that just opened, then ask again.)")
                }
                self.status = route.statusText
            }
            var system = Prompts.system(
                context: context, memories: self.memory.items, spoken: viaVoice,
                personality: self.settings.voicePersonality, speaking: self.speakingThisTurn,
                voiceCues: self.speakingThisTurn && self.speaker.supportsCues
            )
            if forLiveVoice { system += Prompts.liveBackendAddendum }
            system += Prompts.speechAlternatives(heard: text, alsoHeard: alsoHeard)
            await self.execute(route, history: history + [turn], system: system, question: text, replyID: reply.id)
            guard !Task.isCancelled else { return }
            self.finishTurn(reply.id)
        }
    }

    func stop() {
        cancelWork()
        live.close()
        speaker.stop()
        if listener.isListening { listener.stop(send: false) }
        if phase == .listening { phase = .idle }
    }

    func newChat() {
        stop()
        messages = []
        currentReplyID = nil
        currentQuestion = ""
        phase = .idle
        History.save(messages)
    }

    // MARK: - Running a request

    private func execute(_ route: Route, history: [Turn], system: String, question: String, replyID: UUID) async {
        do {
            try await run(route, history: history, system: system, question: question, replyID: replyID)
        } catch {
            if Task.isCancelled { return }
            guard settings.mode == .auto, text(of: replyID).isEmpty,
                  let alternative = Router.alternative(to: route, settings: settings, text: question)
            else { return show(error, in: replyID) }

            update(replyID) { $0.engine = alternative.label }
            status = alternative.statusText
            do {
                try await run(alternative, history: history, system: system, question: question, replyID: replyID)
            } catch {
                if Task.isCancelled { return }
                show(error, in: replyID)
            }
        }
    }

    private func run(_ route: Route, history: [Turn], system: String, question: String, replyID: UUID) async throws {
        let usesPlan: Bool
        if case .chatGPTPlan = settings.openAIAuth {
            usesPlan = route.kind == .council ? settings.isAvailable(.openai) : (route.kind != .local && route.provider == .openai)
        } else {
            usesPlan = false
        }
        if usesPlan { update(replyID) { $0.usedPlan = true } }

        switch route.kind {
        case .local:
            if let command = route.command { emit(LocalCommands.run(command), to: replyID) }
        case .chat:
            // Hold back the first few characters, in case the model hands the request over to the Mac agent.
            var head = ""
            var decided = false
            for try await delta in stream(route, system: system + Prompts.actionHandoff, history: history) {
                if decided {
                    emit(delta, to: replyID)
                    continue
                }
                head += delta
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix(Prompts.actionMarker) {
                    let agent = Router.agent(route.provider, settings)
                    update(replyID) { $0.engine = agent.label }
                    status = agent.statusText
                    return try await run(agent, history: history, system: system, question: question, replyID: replyID)
                }
                if trimmed.count >= Prompts.actionMarker.count || !Prompts.actionMarker.hasPrefix(trimmed) {
                    decided = true
                    emit(head, to: replyID)
                }
            }
            if !decided, !head.isEmpty { emit(head, to: replyID) }
        case .agent:
            let answer: String
            if route.provider == .claude {
                answer = try await ClaudeClient.runAgent(
                    key: settings.key(for: .claude), model: route.model, system: system + Prompts.agentAddendum,
                    history: history, effort: route.effort
                ) { [weak self] in self?.status = $0 }
            } else {
                answer = try await TextAgent.run(
                    history: history, system: system + Prompts.agentAddendum,
                    step: { [unowned self] turns, prompt in self.stream(route, system: prompt, history: turns) },
                    onStatus: { [weak self] in self?.status = $0 }
                )
            }
            emit(answer.isEmpty ? "Done." : answer, to: replyID)
        case .council:
            try await council(history: history, question: question, system: system, replyID: replyID)
        }
        if text(of: replyID).isEmpty { emit("(No response.)", to: replyID) }
    }

    private func stream(_ route: Route, system: String, history: [Turn]) -> AsyncThrowingStream<String, Error> {
        switch route.provider {
        case .claude:
            return ClaudeClient.stream(key: settings.key(for: .claude), model: route.model, system: system, history: history, effort: route.effort)
        case .openai:
            return OpenAIClient.stream(auth: settings.openAIAuth, model: route.model, system: system, history: history, webSearch: route.grounded)
        case .gemini:
            return GeminiClient.stream(key: settings.key(for: .gemini), model: route.model, system: system, history: history, grounded: route.grounded)
        }
    }

    /// Asks every available model at once, then has one model (Claude when possible) merge the answers.
    private func council(history: [Turn], question: String, system: String, replyID: UUID) async throws {
        let members = Provider.allCases.filter(settings.isAvailable)
        status = "Thinking really hard…"
        let streams = members.map { ($0, stream(Router.chatRoute(for: $0, settings: settings, text: question), system: system, history: history)) }

        let answers = await withTaskGroup(of: (Provider, String?).self, returning: [(Provider, String)].self) { group in
            for (provider, stream) in streams {
                group.addTask { (provider, try? await SSE.collect(stream)) }
            }
            var collected: [(Provider, String)] = []
            for await (provider, answer) in group {
                if let answer, !answer.isEmpty { collected.append((provider, DisplayText.clean(MemoryStore.extract(from: answer).clean))) }
            }
            return collected.sorted { $0.0.order < $1.0.order }
        }
        try Task.checkCancellation()

        guard let first = answers.first else { throw APIError.badResponse("Saturday couldn't get an answer. Check Settings → Accounts.") }
        if answers.count == 1 {
            emit(first.1, to: replyID)
            return
        }

        let judge = settings.isAvailable(.claude)
            ? Route(kind: .chat, provider: .claude, model: settings.claudeModel, effort: "high", reason: "judge")
            : Router.chatRoute(for: first.0, settings: settings, text: question)
        status = "Putting it all together…"
        let synthesis = Array(history.dropLast()) + [Turn(role: .user, text: Prompts.councilSynthesis(question: question, answers: answers))]
        for try await delta in stream(judge, system: system, history: synthesis) {
            emit(delta, to: replyID)
        }
    }

    // MARK: - Helpers

    /// Shows new reply text and feeds it to the voice as it arrives.
    private func emit(_ delta: String, to id: UUID) {
        update(id) { $0.text += delta }
        if phase == .thinking { phase = .responding }
        if speakingThisTurn { speaker.feed(delta) }
    }

    private func finishTurn(_ id: UUID) {
        let (clean, facts) = MemoryStore.extract(from: text(of: id))
        let shown = DisplayText.clean(clean).trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.text = shown.isEmpty ? $0.text : shown }
        facts.forEach(memory.add)
        if speakingThisTurn { speaker.finish() }
        // In a live conversation the voice agent is about to say the answer.
        phase = live.isActive ? .responding : .done
        status = ""
        History.save(messages)
        if let reply = messages.first(where: { $0.id == id }), let completion = turnCompletion {
            turnCompletion = nil
            completion(reply)
        }
        let failed = messages.first { $0.id == id }?.isError ?? false
        awaitingFollowUp = followUpEligible && !failed
        if !speaker.isSpeaking { listenForFollowUp() }
    }

    private func cancelWork() {
        if turnCompletion != nil {
            // A newer request replaced a delegated one; let the voice session time out normally again.
            turnCompletion = nil
            live.setBusy(false)
        }
        guard let task else { return }
        task.cancel()
        self.task = nil
        if let id = currentReplyID { update(id) { $0.text = $0.text.isEmpty ? "Stopped." : $0.text } }
        if isWorking { phase = .done }
        status = ""
    }

    /// The last 20 successful messages, starting with a user turn, sent as context.
    private func turns() -> [Turn] {
        var recent = messages.filter { !$0.isError && !$0.text.isEmpty }.suffix(20)
        while recent.first?.role == .assistant { recent.removeFirst() }
        return recent.map { Turn(role: $0.role, text: $0.text) }
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func text(of id: UUID) -> String { messages.first { $0.id == id }?.text ?? "" }

    private func show(_ error: Error, in id: UUID) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        update(id) {
            if $0.text.isEmpty {
                $0.text = message
                $0.isError = true
            } else {
                $0.text += "\n\n(Stopped: \(message))"
            }
        }
        if speakingThisTurn, text(of: id) == message { speaker.feed(message) }
    }
}
