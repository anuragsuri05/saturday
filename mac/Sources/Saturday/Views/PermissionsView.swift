import SwiftUI

/// The live checklist of permissions with one "Allow everything" button. Used in onboarding, the setup
/// window and Settings.
struct PermissionList: View {
    @ObservedObject var permissions: Permissions
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            ForEach(Permissions.Kind.allCases) { kind in
                row(kind)
            }
        }
        .onAppear {
            permissions.refresh()
            permissions.startWatching()
        }
    }

    private func row(_ kind: Permissions.Kind) -> some View {
        let status = permissions.status(kind)
        let waiting = permissions.waitingFor == kind
        return HStack(spacing: 12) {
            GlossyCircle(fill: status == .granted ? AnyShapeStyle(LinearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom))
                                                  : AnyShapeStyle(Theme.accent),
                         size: compact ? 28 : 32, glow: status == .granted ? .green : .pink)
                .overlay {
                    Image(systemName: kind.symbol)
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(kind.title).font(Theme.rounded(compact ? 13 : 14))
                    if !kind.essential { Text("Optional").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Text(waiting ? hint(kind) : kind.detail)
                    .font(.caption)
                    .foregroundStyle(waiting ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .missing, .denied:
                if waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(status == .denied ? "Open Settings" : "Allow") {
                        Task { await permissions.request(kind) }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassInset(Capsule(), highlighted: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 6 : 8)
        .glassInset(RoundedRectangle(cornerRadius: 14, style: .continuous), highlighted: waiting)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: status)
        .animation(.easeOut(duration: 0.2), value: waiting)
    }

    private func hint(_ kind: Permissions.Kind) -> String {
        switch kind {
        case .accessibility: "Turn on Saturday in the window that opened"
        case .screen: "Turn on Saturday in System Settings"
        case .automation: "Click OK on each prompt"
        case .fullDisk: "Turn on Saturday, or add it with +"
        default: "Click Allow on the prompt"
        }
    }
}

/// The big "Allow everything" button, which walks through every permission in order.
struct AllowEverythingButton: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        Button {
            Task { await permissions.grantAll() }
        } label: {
            HStack(spacing: 8) {
                if permissions.isGranting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: permissions.allEssentialGranted ? "checkmark.seal.fill" : "lock.open.fill")
                }
                Text(permissions.isGranting ? "Setting up…" : permissions.allEssentialGranted ? "Everything's on" : "Allow Everything")
            }
            .font(Theme.rounded(16))
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background { GlossyCapsule() }
        }
        .buttonStyle(.plain)
        .disabled(permissions.isGranting || permissions.allEssentialGranted)
    }
}

/// A shiny capsule for the main call to action.
struct GlossyCapsule: View {
    var colors: [Color] = [.pink, .orange]

    var body: some View {
        ZStack {
            Capsule().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .center))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .blur(radius: 0.5)
            Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        }
        .shadow(color: (colors.first ?? .pink).opacity(0.5), radius: 12, y: 5)
    }
}

/// The standalone setup window: shown at launch until the essentials are on, or when a task needs one.
struct PermissionsSetupView: View {
    @ObservedObject var permissions: Permissions
    var close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            PermissionsIntro(permissions: permissions)
            PermissionList(permissions: permissions)
            HStack {
                Spacer()
                if permissions.allEssentialGranted {
                    Button("Done", action: close)
                        .buttonStyle(.plain)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background { GlossyCapsule() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .padding(28)
        .frame(width: 520)
        .background { AuroraBackground() }
    }
}

/// Heading, explanation and the "Allow Everything" button.
struct PermissionsIntro: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 10) {
            Text("Give Saturday the keys").font(Theme.rounded(28, .bold))
            Text("Allow everything once, now, and Saturday never has to ask again. It can then see your screen, click and type in any app, control Music and your browser, and find your files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AllowEverythingButton(permissions: permissions)
                .padding(.top, 4)
            Text("\(permissions.grantedCount) of \(Permissions.Kind.allCases.count) on · You can change these anytime in System Settings")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())
        }
    }
}
