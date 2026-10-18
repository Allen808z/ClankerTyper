import AppKit

/// Watches the talk key chosen in Settings (Control + Option by default) and reports press and
/// release, whether Shift joined it (command mode), and whether another key was pressed while
/// it was held (then the hold was a normal shortcut, not dictation).
/// The global monitors need Accessibility permission; without it the key only works while
/// ClankerTyper itself is frontmost.
@MainActor
final class PushToTalk {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called once per hold when Shift is down together with the talk key.
    var onShift: (() -> Void)?
    /// Called once per hold when a non-modifier key is pressed while the talk key is held.
    var onOtherKey: (() -> Void)?

    private var monitors: [Any] = []
    private(set) var isHeld = false
    private var shiftReported = false
    private var otherKeyReported = false

    func start() {
        guard monitors.isEmpty else { return }
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            let raw = event.modifierFlags.rawValue
            DispatchQueue.main.async { self?.update(raw: raw) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            flagsHandler(event)
            return event
        }) {
            monitors.append(local)
        }
        let keyHandler: (NSEvent) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.keyPressed() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            keyHandler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isHeld = false
    }

    private func update(raw: UInt) {
        let held = AppSettings.talkKey.isHeld(raw: raw)
        if held, !isHeld {
            isHeld = true
            shiftReported = false
            otherKeyReported = false
            onPress?()
        }
        if held, isHeld, !shiftReported, NSEvent.ModifierFlags(rawValue: raw).contains(.shift) {
            shiftReported = true
            onShift?()
        }
        if !held, isHeld {
            isHeld = false
            onRelease?()
        }
    }

    private func keyPressed() {
        guard isHeld, !otherKeyReported else { return }
        otherKeyReported = true
        onOtherKey?()
    }
}
