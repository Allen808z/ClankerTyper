import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import Speech

enum PermissionKind: CaseIterable, Identifiable {
    case microphone
    case speech
    case screen
    case accessibility

    var id: Self { self }

    /// Transcribe-only mode never captures the screen, so Screen Recording is not needed.
    static func required(transcribeOnly: Bool) -> [PermissionKind] {
        transcribeOnly ? [.microphone, .speech, .accessibility] : allCases
    }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .screen: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone: return "So Clanker can hear you while you hold the shortcut."
        case .speech: return "To turn what you say into text on this Mac."
        case .screen: return "To see your screen when you ask for help. Restart Clanker after allowing."
        case .accessibility: return "To notice the Control + Option shortcut while you use other apps."
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .screen: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

/// Reads and requests the four permissions. Status is always read live; nothing is cached.
enum Permissions {
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech:
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .screen:
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Asks macOS for the permission when it still can, otherwise opens the right Settings pane.
    static func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                open(kind)
            }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { _ in }
            } else {
                open(kind)
            }
        case .screen:
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
            open(kind)
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            open(kind)
        }
    }

    static func open(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
