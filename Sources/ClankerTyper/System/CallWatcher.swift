import AppKit
import ApplicationServices
import CoreAudio

/// Notices when a call starts: another app begins using the microphone while a call app (or a
/// browser on a meeting page) is in front. It offers once per call; nothing records without the
/// user's click.
@MainActor
final class CallWatcher {
    /// Called with the call app's name and bundle identifier.
    var onCallStarted: ((String, String?) -> Void)?
    /// True while ClankerTyper itself uses the microphone, which hides other apps' use of it.
    var isOwnMicrophoneActive: (() -> Bool)?

    private var timer: Timer?
    private var micWasInUse = false
    private var offeredThisCall = false

    /// Apps whose main job is calls.
    nonisolated static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "Cisco-Systems.Spark": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.skype.skype": "Skype",
    ]

    nonisolated static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Window titles that mean a browser tab is a meeting.
    nonisolated static let meetingTitles: [(String, String)] = [
        ("meet.google.com", "Google Meet"), ("Google Meet", "Google Meet"), ("Meet - ", "Google Meet"),
        ("Zoom", "Zoom"), ("Microsoft Teams", "Microsoft Teams"), ("Webex", "Webex"),
        ("Whereby", "Whereby"), ("Jitsi", "Jitsi Meet"),
    ]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // While ClankerTyper records, the microphone is "in use" because of it; say nothing.
        guard isOwnMicrophoneActive?() != true else { return }
        let inUse = Self.microphoneInUse()
        if inUse, !micWasInUse { offeredThisCall = false }
        micWasInUse = inUse
        guard inUse, !offeredThisCall else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let title = front.flatMap { Self.focusedWindowTitle(pid: $0.processIdentifier) }
        guard let name = Self.callName(frontmostBundleID: front?.bundleIdentifier, frontWindowTitle: title) else { return }
        offeredThisCall = true
        AppLog.write("a call started in \(name)")
        onCallStarted?(name, front?.bundleIdentifier)
    }

    /// The call's app name when the app in front is a call app, or a browser on a meeting page.
    nonisolated static func callName(frontmostBundleID: String?, frontWindowTitle: String?) -> String? {
        guard let bundleID = frontmostBundleID else { return nil }
        if let name = callApps[bundleID] { return name }
        guard browsers.contains(bundleID), let title = frontWindowTitle else { return nil }
        return meetingTitles.first { title.localizedCaseInsensitiveContains($0.0) }?.1
    }

    /// True when any process is using the default microphone.
    static func microphoneInUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return false
        }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}
