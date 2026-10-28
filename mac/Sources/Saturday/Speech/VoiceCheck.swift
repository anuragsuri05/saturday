import ApplicationServices
import Foundation
import os

/// Startup checks for Saturday's voice: warms up the on-device voice (the first synthesis is slow) and
/// records whether it works and how fast, and whether OpenAI's speech service accepts the ChatGPT login.
/// Results go to the unified log (subsystem com.saturday.assistant) and to UserDefaults "voiceCheck.*".
@MainActor
enum VoiceCheck {
    private static let log = Logger(subsystem: "com.saturday.assistant", category: "voice-check")

    static func run() async {
        record("accessibility", AXIsProcessTrusted() ? "granted" : "not granted")
        await checkOfflineVoice()
        // OpenAI's answer for the ChatGPT login doesn't change often; check it once.
        if UserDefaults.standard.string(forKey: "voiceCheck.gptSpeech") == nil { await checkGPTSpeechWithChatGPT() }
    }

    /// Synthesizes a short phrase with Kokoro without playing it: warms the model and measures speed.
    static func checkOfflineVoice() async {
        guard LocalVoice.shared.isReady else {
            record("offline", "not installed")
            return
        }
        do {
            // The first run includes one-time warm-up; the second shows real speed.
            let cold = try await synthesize("Hey, I'm Saturday.")
            let warm = try await synthesize("Hey, I'm Saturday. How can I help you today?")
            record("offline", String(format: "%@ ok: warm-up %.1fs; then %.2fs of speech in %.2fs (%.1fx real time)",
                                     SettingsStore.shared.localModel.rawValue, cold.time, warm.audio, warm.time, warm.audio / max(warm.time, 0.001)))
        } catch {
            record("offline", "failed: \(error.localizedDescription)")
        }
    }

    private static func synthesize(_ text: String) async throws -> (audio: Double, time: Double) {
        let started = Date()
        var bytes = 0
        let settings = SettingsStore.shared
        for try await chunk in NeuralVoiceEngine.shared.stream(text: text, model: settings.localModel, speaker: settings.localSpeaker, speed: 1.0) {
            bytes += chunk.count
        }
        return (Double(bytes / 2) / 24000, Date().timeIntervalSince(started))
    }

    /// One tiny request to OpenAI's text-to-speech endpoint with the ChatGPT login.
    private static func checkGPTSpeechWithChatGPT() async {
        guard ChatGPTAccount.shared.planEnabled, let token = try? await ChatGPTAccount.currentAccessToken() else {
            record("gptSpeech", "skipped: not signed in with ChatGPT")
            return
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts", "voice": "marin", "input": "Hi.", "response_format": "pcm",
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                record("gptSpeech", "accepted: \(data.count) bytes of audio")
            } else {
                record("gptSpeech", "rejected: HTTP \(status) \(SSE.errorMessage(String(decoding: data, as: UTF8.self)))")
            }
        } catch {
            record("gptSpeech", "failed: \(error.localizedDescription)")
        }
    }

    private static func record(_ key: String, _ result: String) {
        UserDefaults.standard.set(result, forKey: "voiceCheck.\(key)")
        log.notice("\(key, privacy: .public): \(result, privacy: .public)")
    }
}
