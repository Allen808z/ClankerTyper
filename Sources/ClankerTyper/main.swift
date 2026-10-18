import AppKit

// Menu bar companion: no Dock icon, no main window.
// Top-level code runs on the main thread, which is the main actor's executor.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(AppSettings.activationPolicy)
    application.run()
}
