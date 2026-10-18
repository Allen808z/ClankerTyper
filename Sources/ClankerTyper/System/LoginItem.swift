import Foundation
import ServiceManagement

/// Opens ClankerTyper when the user logs in, through macOS Login Items.
@MainActor
enum LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but the user has to allow it in System Settings → General → Login Items.
        case needsApproval
        /// Not the copy in Applications (for example the development build), so nothing is registered.
        case notInstalled
    }

    static var isInstalledCopy: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static var state: State {
        guard isInstalledCopy else { return .notInstalled }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Makes Login Items match the setting. Safe to call on every launch.
    static func apply(_ enabled: Bool) {
        guard isInstalledCopy else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
                AppLog.write("added ClankerTyper to Login Items")
            } else if !enabled, service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                AppLog.write("removed ClankerTyper from Login Items")
            }
        } catch {
            AppLog.write("could not update Login Items: \(error.localizedDescription)")
        }
    }
}
