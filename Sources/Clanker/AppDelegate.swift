import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CompanionController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = CompanionController()
        self.controller = controller
        controller.start()
        controller.showStartWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
