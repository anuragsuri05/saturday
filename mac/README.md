# Saturday for Mac

A Siri-style assistant that combines **Claude, ChatGPT and Gemini** and picks the best one for each request. It stays hidden in the menu bar. Press **⌥ Space** in any app and Saturday slides in on the right of the screen with a glowing orb and starts listening. You can also double-press Fn or Right ⌘ (set this in Settings).

**What makes it smart**
- **Knows what you're doing:** it reads the app you're in, your selected text, and a screenshot when you say "this" or "my screen".
- **Remembers you:** it picks up lasting facts from conversation, or you can say "remember that…". You can edit everything in Settings, and it's stored only on this Mac.
- **Does things:** Mac actions work with Claude, ChatGPT or Gemini.
- **Answers well:** it routes each request to the best model, can have all three answer together (Council), and has a Genius mode that uses Claude Fable 5.1.

**Voice**
- **Natural voice:** it uses Gemini 3.8 Flash TTS with your free Gemini key, ElevenLabs Flash v2.5 (optional), or the best Apple Premium voice offline.
- **Fast:** it starts speaking at the first sentence. Speech is recognized on the Mac itself, it sends after a 0.9-second pause, and connections are opened when you summon it.
- **Brief:** only the short summary is spoken. The details appear in the card on screen.

**Permissions** are asked for all at once on first launch (onboarding, or the "Set up Saturday" window): Microphone, Speech Recognition, Accessibility (click and type in any app), Screen Recording, App Control (Apple Events for Music, Chrome, Safari, Finder, Notes, Reminders, Calendar…) and, optionally, Full Disk Access. Click **Allow Everything** and Saturday walks through each one. They live in Settings → Access afterwards.

## Build and run

Requires macOS 14+ and the Swift toolchain (the Xcode Command Line Tools are enough).

```bash
cd mac
./scripts/build_app.sh            # builds build/Saturday.app
open build/Saturday.app
./scripts/build_app.sh --install  # also copies it to /Applications
```

## Connecting your AI accounts

| Provider | How you connect | Why |
|---|---|---|
| **ChatGPT** | **Continue with ChatGPT**: sign in in your browser. No API key. Requests use your Plus or Pro plan. | OpenAI's [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) supports open-source and locally run apps. |
| **Claude** | API key ([get one](https://console.anthropic.com/settings/keys)) | Since February 2026, Anthropic only allows Claude Free/Pro/Max sign-in inside Claude Code and Claude.ai. Other apps that use it get accounts blocked. |
| **Gemini** | Free API key ([AI Studio](https://aistudio.google.com/apikey)) | Google has no approved way for other apps to use a Gemini subscription. Reusing the Gemini CLI login breaks Google's terms. |

ChatGPT on its own is enough to start. Simple Mac commands ("open Safari", "volume 30", "search for…") run on-device and need no account at all.

How the ChatGPT sign-in works (`ChatGPTAccount.swift`):
- OAuth with PKCE uses a one-time listener on `127.0.0.1:1455`, with dynamic client registration (`dynamic_agent_client`).
- The ID token's signature is checked against OpenAI's published keys.
- Tokens refresh automatically and are revoked when you sign out.
- Tokens are stored in `~/Library/Application Support/Saturday/chatgpt-account.json` with owner-only access.
- Requests go to the Responses API with `store: false`.
- Usage limits show a **Manage usage** link, as OpenAI requires.

> Sharing a ChatGPT plan is allowed for open-source and locally run apps. If you ever sell Saturday or host it remotely, you first need to apply through OpenAI's [interest form](https://openai.com/form/sign-in-with-chatgpt-interest/).

API keys for Claude and Gemini are stored in the macOS Keychain. You can change model IDs in Settings, and the ChatGPT model list comes from your account.

## What it does

- **Auto routing** (no extra API call):
  - Mac actions → Claude with tools
  - Live or current info → Gemini with Google Search grounding
  - Coding, maths and analysis → Claude Opus at high effort
  - Creative writing → ChatGPT
  - Short questions → Claude Haiku
  - Anything else → Claude Opus

  If a provider fails or has no key, Saturday falls back to another provider.
- **Council mode:** asks every model you have a key for at the same time, then Claude merges the best parts into one answer.
- **Fixed modes:** always use Claude, ChatGPT or Gemini.
- **Mac actions:** open apps and URLs, set the volume, read and write the clipboard, web search, and AppleScript for Music, Notes, Reminders, Calendar, Mail and Finder. You approve every AppleScript before it runs.
- **Voice:** tap the mic and speak. Saturday sends when you pause and reads the reply aloud.
- Streaming replies, conversation memory (the last 20 messages are sent as context), and history saved in `~/Library/Application Support/Saturday/`.

## Code map

| File | Role |
|---|---|
| `SaturdayApp.swift` | App entry, menu bar item, floating panel, menus |
| `Assistant.swift` | Conversation engine: routing, streaming, fallback, council |
| `Router.swift` | Model choice plus system prompts |
| `Providers/` | Claude, OpenAI (Responses API) and Gemini clients over raw HTTP and SSE |
| `ChatGPTAccount.swift` | Sign in with ChatGPT: OAuth, ID-token checks, refresh, sign-out |
| `Overlay/` | Right-side Siri-style panel: orb, edge glow, burst animation, answer card |
| `Speech/` | On-device speech recognition; streaming natural voice that speaks sentence by sentence |
| `Context.swift` | Frontmost app, selected text, screenshot, connection warm-up |
| `Memory.swift` | What Saturday knows about you |
| `TextAgent.swift` | Mac actions for ChatGPT and Gemini (tool calls written as tags) |
| `LocalCommands.swift` | Instant on-device commands that need no account |
| `MacTools.swift` | Tools Claude can call on the Mac |
| `Voice.swift` | Speech recognition and text-to-speech |
| `HotKey.swift` | Global ⌥Space shortcut |
| `Views/` | SwiftUI chat and settings |

## Notes

- `scripts/build_app.sh` signs the app with a local self-signed certificate ("Saturday Local Signing", kept in `~/Library/Keychains/saturday-signing.keychain-db`), so permissions you grant survive rebuilds. If that keychain is deleted, the script creates a new certificate and macOS asks for permissions once more.
- ⌥Space is also the ChatGPT desktop app's default shortcut. If you use both, change one of them (`HotKey.swift`).

## Roadmap

1. "Hey Saturday" wake word, and a reply overlay you can glance at.
2. Image and screenshot input ("what's on my screen?").
3. Long-term memory of user preferences.
4. **iPhone:** reuse `Providers/`, `Router.swift` and `Assistant.swift` in an iOS SwiftUI app, plus a Siri Shortcut / App Intent ("Hey Siri, ask Saturday…").
5. **Android:** Kotlin + Jetpack Compose app with the same router logic, set as the default digital assistant.
6. Optional small backend so keys aren't needed on every device.
