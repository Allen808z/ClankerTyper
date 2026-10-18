import AppKit

/// Watches the Control + Option modifier pair and reports press and release, and whether Shift
/// was part of the chord (Control + Option + Shift is command mode).
/// The global monitor needs Accessibility permission; without it the shortcut only works
/// while ClankerTyper itself is frontmost.
@MainActor
final class PushToTalk {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Called once per hold when Shift is down together with Control + Option.
    var onShift: (() -> Void)?

    private var monitors: [Any] = []
    private(set) var isHeld = false
    private var shiftReported = false

    static func isChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
        return relevant.contains(.control) && relevant.contains(.option) && !relevant.contains(.command)
    }

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { self?.update(flags: event.modifierFlags) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        if let local { monitors.append(local) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        isHeld = false
    }

    private func update(flags: NSEvent.ModifierFlags) {
        let chord = Self.isChord(flags)
        if chord, !isHeld {
            isHeld = true
            shiftReported = false
            onPress?()
        }
        if chord, isHeld, !shiftReported, flags.contains(.shift) {
            shiftReported = true
            onShift?()
        }
        if !chord, isHeld {
            isHeld = false
            onRelease?()
        }
    }
}
