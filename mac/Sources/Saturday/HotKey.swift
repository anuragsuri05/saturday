import AppKit
import Carbon

enum ExtraTrigger: String, CaseIterable, Identifiable {
    case none, doubleFn, doubleRightCommand
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Only ⌥ Space"
        case .doubleFn: "Also double-press Fn / 🌐"
        case .doubleRightCommand: "Also double-press Right ⌘"
        }
    }
}

/// A system-wide shortcut (⌥Space) using Carbon, which needs no permissions.
final class HotKey {
    private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping () -> Void) {
        HotKey.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &eventType, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5341_5455), id: 1) // "SATU"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }
}

/// ⌥Space plus an optional double-press of Fn or Right ⌘ (that one needs Accessibility access).
@MainActor
final class TriggerManager {
    private let action: () -> Void
    private var hotKey: HotKey?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastPress: TimeInterval = 0

    init(action: @escaping () -> Void) {
        self.action = action
        hotKey = HotKey { Task { @MainActor in action() } }
    }

    func setExtra(_ extra: ExtraTrigger) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        guard extra != .none else { return }
        if !ContextReader.hasAccessibility { ContextReader.requestAccessibility() }

        let (keyCode, flag): (UInt16, NSEvent.ModifierFlags) = extra == .doubleFn ? (63, .function) : (54, .command)
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == keyCode, event.modifierFlags.contains(flag) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastPress < 0.4 {
                self.lastPress = 0
                self.action()
            } else {
                self.lastPress = now
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }
}
