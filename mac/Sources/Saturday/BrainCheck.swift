import Foundation

/// A developer check, run only when Saturday is launched with `--brain-check`: sends misheard music requests
/// to the connected ChatGPT model and records which tool call it chooses, without running the tool.
/// Results go to UserDefaults "brainCheck.*".
@MainActor
enum BrainCheck {
    static func runIfRequested() async {
        guard CommandLine.arguments.contains("--brain-check") else { return }
        let settings = SettingsStore.shared
        guard settings.isAvailable(.openai) else {
            UserDefaults.standard.set("skipped: no ChatGPT connection", forKey: "brainCheck.status")
            return
        }
        let cases: [(name: String, heard: String, alsoHeard: [String])] = [
            ("1 play music", "Play music", []),
            ("2 song", "Play tum hi ho", []),
            ("3 chrome", "Check out my Chrome", []),
            ("4 tabs", "What tabs do I have open", []),
            ("5 youtube", "Open YouTube in a new tab in Chrome", []),
            ("6 dark mode", "Turn on dark mode", []),
            ("7 app click", "Click the shuffle button in Music", []),
            ("8 pause", "Pause", []),
            ("9 question", "What type of food is good for breakfast", []),
            ("10 polite apple music", "Can you please open Apple Music and search for Rahima by Saiya Bhakar?", []),
            ("11 youtube music", "Can you please open Whitey music and search for Rahima by Sai Bhayankar?", []),
            ("12 screen", "Okay, can you please see my screen? What's on my screen right now?", []),
            ("13 chat", "Do you know about me?", []),
            ("14 text meaning", "What does this text mean in French: bonjour", []),
        ]
        for test in cases {
            let route = Router.route(test.heard, mode: .auto, settings: settings, hasSelection: false)
            if route.kind == .local {
                UserDefaults.standard.set("route=on-device (instant, no AI)", forKey: "brainCheck.\(test.name)")
                continue
            }
            var system = Prompts.system(context: ScreenContext(), memories: [], spoken: true,
                                        personality: settings.voicePersonality, speaking: false, voiceCues: false)
            system += Prompts.speechAlternatives(heard: test.heard, alsoHeard: test.alsoHeard)
            system += route.kind == .chat ? Prompts.actionHandoff : Prompts.agentAddendum + TextAgent.toolPrompt
            let stream = OpenAIClient.stream(auth: settings.openAIAuth, model: settings.openAIModel, system: system,
                                             history: [Turn(role: .user, text: test.heard)])
            let result: String
            do {
                result = try await SSE.collect(stream).replacingOccurrences(of: "\n", with: " ")
            } catch {
                result = "error: \(error.localizedDescription)"
            }
            UserDefaults.standard.set("route=\(route.kind) → \(result.prefix(400))", forKey: "brainCheck.\(test.name)")
        }
        UserDefaults.standard.set("done", forKey: "brainCheck.status")
    }
}
