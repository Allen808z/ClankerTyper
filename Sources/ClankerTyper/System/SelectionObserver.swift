import AppKit
import ApplicationServices

/// Listens, through Accessibility, for the app in front to report that its text selection or
/// focused field changed. This covers every way of highlighting: dragging, double-clicking,
/// Shift+arrow keys, Cmd+A.
@MainActor
final class SelectionObserver {
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var pid: pid_t = 0

    private static let notifications = [kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification]

    /// Starts listening to `app`, and stops listening to the previous one.
    func follow(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != pid else { return }
        stop()
        // Never watch ClankerTyper itself.
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let target = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<SelectionObserver>.fromOpaque(refcon).takeUnretainedValue()
            // The run loop source is on the main run loop, so this runs on the main thread.
            MainActor.assumeIsolated { me.onChange?() }
        }
        guard AXObserverCreate(target, callback, &created) == .success, let created else { return }

        let element = AXUIElementCreateApplication(target)
        // Electron apps only report their text once asked to; harmless elsewhere.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        appElement = element
        pid = target
    }

    func stop() {
        if let observer, let appElement {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, appElement, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = 0
    }
}
