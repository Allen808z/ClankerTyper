import AppKit

/// A menu item that runs a closure, for menus built on the fly.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used from Interface Builder")
    }

    @objc private func fire() { handler() }
}
