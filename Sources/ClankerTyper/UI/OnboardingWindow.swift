import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionState
    let finish: () -> Void
    @AppStorage(AppSettings.Key.transcribeOnly) private var transcribeOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to ClankerTyper")
                .font(.system(size: 22, weight: .bold))
            Text(transcribeOnly
                 ? "Hold Control + Option and speak, and ClankerTyper writes down what you say. It never looks at your screen. Allow these so it works:"
                 : "A small blue helper that sits on your Mac. Hold Control + Option and ask it anything; it can see your screen when you ask and point at what it means. Allow these so it works:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(PermissionKind.required(transcribeOnly: transcribeOnly)) { kind in
                    PermissionRow(kind: kind, granted: permissions.granted[kind] ?? false) {
                        Permissions.request(kind)
                    }
                }
            }

            HStack {
                Button("Not now", action: finish)
                Spacer()
                Button(permissions.allGranted ? "Start" : "Continue", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    let permissions: PermissionState

    init(permissions: PermissionState) {
        self.permissions = permissions
    }

    func show() {
        if window == nil {
            let view = OnboardingView(permissions: permissions) { [weak self] in
                AppSettings.onboardingDone = true
                self?.window?.orderOut(nil)
            }
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
            created.title = "ClankerTyper"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
