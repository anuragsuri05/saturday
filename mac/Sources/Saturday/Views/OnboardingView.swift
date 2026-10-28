import SwiftUI

/// First-run welcome: meet Saturday, connect an account, pick a personality, learn the shortcut.
struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var account: ChatGPTAccount
    var preview: () -> Void
    var openSettings: () -> Void
    var finish: () -> Void

    @ObservedObject private var permissions = Permissions.shared
    @State private var step = 0
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: connect
                case 2: access
                case 3: personality
                default: tryIt
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)

            footer
        }
        .frame(width: 620, height: 680)
        .background { AuroraBackground() }
    }

    private var access: some View {
        VStack(spacing: 16) {
            PermissionsIntro(permissions: permissions)
            PermissionList(permissions: permissions, compact: true)
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            ZStack {
                BurstRing(trigger: UUID())
                OrbView(phase: .listening, level: 0.15, size: 170)
            }
            Text("Meet Saturday").font(Theme.rounded(38, .bold))
            Text("Your own assistant for the Mac. It hears you, sees what you're working on, remembers what matters to you, and gets things done.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var connect: some View {
        VStack(spacing: 18) {
            GlossyCircle(fill: Theme.accent, size: 76)
                .overlay {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                }
            Text("Connect your account").font(Theme.rounded(30, .bold))
            Text("Sign in once and Saturday is ready. No API keys needed.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if account.planEnabled {
                Label("Connected as \(account.email)", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            } else {
                ContinueWithChatGPTButton(account: account)
                if let error = account.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            Button("Add more accounts for extra powers (free natural voice, live web)…", action: openSettings)
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var personality: some View {
        VStack(spacing: 18) {
            Text("Choose Saturday's vibe").font(Theme.rounded(30, .bold))
            Text("This sets how Saturday sounds and talks. Tap one to hear it.")
                .foregroundStyle(.secondary)
            PersonalityPicker(settings: settings, preview: preview)
        }
    }

    private var tryIt: some View {
        VStack(spacing: 20) {
            OrbView(phase: .idle, level: 0, size: 120)
            Text("You're all set").font(Theme.rounded(32, .bold))
            Text("From any app, press")
                .font(.title3)
                .foregroundStyle(.secondary)
            KeyCaps(keys: ["⌥", "Space"]).scaleEffect(1.4).padding(.vertical, 6)
            Text("and just talk. Saturday slides in from the right, listens, and answers out loud. Press it again to follow up. Esc to dismiss.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var skippable: Bool {
        (step == 1 && !settings.hasAnyProvider) || (step == 2 && !permissions.allEssentialGranted)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: index == step ? 22 : 7, height: 7)
                }
            }
            Spacer()
            if step > 0 {
                Button("Back") { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            Button {
                if step == steps - 1 {
                    finish()
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { step += 1 }
                }
            } label: {
                Text(step == steps - 1 ? "Try it now" : skippable ? "Skip for now" : "Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background { GlossyCapsule() }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(alignment: .top) { Rectangle().fill(Gloss.rim(0.25)).frame(height: 1) }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
    }
}
