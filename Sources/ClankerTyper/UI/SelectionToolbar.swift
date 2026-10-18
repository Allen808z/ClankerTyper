import AppKit
import SwiftUI

/// A small floating toolbar that appears just above highlighted text in another app, offering
/// "Fix grammar" and "Improve writing". It appears however the text was highlighted (drag,
/// double-click, Shift+arrows, Cmd+A), once the selection settles. It never takes focus, so the
/// other app keeps its selection. It only appears for editable text in apps that report their
/// selection through Accessibility; the keyboard shortcuts work everywhere.
@MainActor
final class SelectionToolbar {
    /// Called with the chosen style and where the selection is.
    var onAction: ((Rewriter.Style, FocusSnapshot) -> Void)?
    /// Asked before showing, so the toolbar stays away while recording or rewriting.
    var isBusy: (() -> Bool)?
    /// The user's saved actions, listed under More.
    var customActions: (() -> [CustomAction])?
    var onManageActions: (() -> Void)?

    private let observer = SelectionObserver()
    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var pendingCheck: DispatchWorkItem?
    private var target: FocusSnapshot?
    /// The selection the toolbar is showing for.
    private var shownSelection: String?
    /// A selection the user closed the toolbar for; not offered again until it changes.
    private var dismissedSelection: String?

    /// Wait this long after the selection last changed, so it is not shown mid-drag or mid-typing.
    nonisolated static let settleDelay: TimeInterval = 0.35
    /// Selections longer than this are not offered (a whole document is better done elsewhere).
    nonisolated static let maxCharacters = 8000

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        observer.onChange = { [weak self] in self?.scheduleCheck() }
        observer.follow(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.hide()
                self?.observer.follow(app)
            }
        }
        // Some apps report their selection when asked but never announce changes, so a mouse
        // release or a key release also triggers a check. A click or scroll elsewhere hides it.
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .keyUp, .scrollWheel]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            let type = event.type
            DispatchQueue.main.async {
                switch type {
                case .leftMouseDown, .scrollWheel: self?.hide()
                default: self?.scheduleCheck()
                }
            }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        observer.stop()
        pendingCheck?.cancel()
        hide()
    }

    // MARK: - Deciding when to show

    /// True when the selected text is worth offering: some letters, not huge.
    nonisolated static func shouldOffer(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
            && trimmed.count <= maxCharacters
            && trimmed.contains(where: \.isLetter)
    }

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func check() {
        guard isBusy?() != true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Still dragging: wait for the button to come up.
        guard NSEvent.pressedMouseButtons == 0 else {
            scheduleCheck()
            return
        }

        let snapshot = FocusTracker.capture()
        guard let element = snapshot.element, !FocusTracker.isSecure(element), FocusTracker.isEditable(element),
              let selected = FocusTracker.selectedText(element), Self.shouldOffer(selected) else {
            // Nothing selected any more (or not editable): take the toolbar away.
            hide()
            shownSelection = nil
            dismissedSelection = nil
            return
        }
        if selected == shownSelection, panel?.isVisible == true { return }
        if selected == dismissedSelection { return }

        target = snapshot
        shownSelection = selected
        show(above: FocusTracker.selectionBounds(element), fallback: NSEvent.mouseLocation)
    }

    // MARK: - Panel

    /// Places the toolbar just above the selection, or below it near the top of the screen.
    /// Falls back to the pointer when the app does not report where the selection is.
    private func show(above selection: CGRect?, fallback pointer: CGPoint) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let size = panel.frame.size

        let anchor = selection.flatMap { rect in
            NSScreen.screens.contains { $0.frame.intersects(rect) } ? rect : nil
        } ?? CGRect(x: pointer.x - 16, y: pointer.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = CGPoint(x: anchor.minX, y: anchor.maxY + 8)
        if origin.y + size.height > area.maxY - 6 {
            origin.y = anchor.minY - size.height - 8
        }
        origin.x = min(max(origin.x, area.minX + 6), area.maxX - size.width - 6)
        origin.y = min(max(origin.y, area.minY + 6), area.maxY - size.height - 6)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }

    private func dismiss() {
        dismissedSelection = shownSelection
        hide()
    }

    private func choose(_ style: Rewriter.Style) {
        hide()
        guard let target else { return }
        self.target = nil
        onAction?(style, target)
    }

    /// The other actions, and the user's own, in a menu under the More button.
    private func showMoreMenu() {
        hideTimer?.invalidate()
        let menu = NSMenu()
        for style in Rewriter.Style.selectionActions where style != .grammar && style != .improve {
            menu.addItem(ClosureMenuItem(style.title) { [weak self] in self?.choose(style) })
        }
        let custom = customActions?() ?? []
        if !custom.isEmpty {
            menu.addItem(.separator())
            for action in custom {
                menu.addItem(ClosureMenuItem(action.name) { [weak self] in self?.choose(.custom(action.instruction)) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add your own action…") { [weak self] in
            self?.hide()
            self?.onManageActions?()
        })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = SelectionToolbarView(
            fix: { [weak self] in self?.choose(.grammar) },
            improve: { [weak self] in self?.choose(.improve) },
            more: { [weak self] in self?.showMoreMenu() },
            close: { [weak self] in self?.dismiss() }
        )
        let hosting = FirstClickHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 352, height: 36)
        panel.contentView = hosting
        return panel
    }
}

/// Never becomes key or main, so clicking it leaves the other app focused (and its selection,
/// or the call window, in front). Used by the selection toolbar and the meeting panel.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click even though ClankerTyper is not the active app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct SelectionToolbarView: View {
    let fix: () -> Void
    let improve: () -> Void
    let more: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ToolbarButton(title: "Fix grammar", symbol: "checkmark.seal", action: fix)
            Divider().frame(height: 16).overlay(Color.white.opacity(0.2))
            ToolbarButton(title: "Improve writing", symbol: "wand.and.stars", action: improve)
            Divider().frame(height: 16).overlay(Color.white.opacity(0.2))
            ToolbarButton(title: "More", symbol: "chevron.down", action: more)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 5)
        .frame(width: 352, height: 36)
        .background(Capsule().fill(Color(white: 0.1).opacity(0.95)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
    }
}

private struct ToolbarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? Brand.accent.opacity(0.85) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
