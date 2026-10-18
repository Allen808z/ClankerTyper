import AppKit
import ScreenCaptureKit

/// Captures the user's displays, but only when a help request is made (never in the background).
enum ScreenCapture {
    struct CapturedScreen {
        let encoded: EncodedScreen
        /// Frame of the display in AppKit screen coordinates.
        let appKitFrame: CGRect
    }

    enum CaptureError: LocalizedError {
        case permissionMissing
        case noDisplays
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .permissionMissing:
                return "ClankerTyper needs Screen Recording permission to see your screen. Allow it, then restart ClankerTyper."
            case .noDisplays:
                return "No display was found to capture."
            case .encodingFailed:
                return "A screenshot could not be encoded."
            }
        }
    }

    /// Captures up to `maxScreens` displays, the one under the mouse first, scaled to `maxWidth`.
    static func captureScreens(maxScreens: Int = 3, maxWidth: Int = 1280) async throws -> [CapturedScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionMissing }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Leave ClankerTyper's own overlay and card out of the picture.
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }

        let mouse = NSEvent.mouseLocation
        let frames = displayFrames()
        let ordered = content.displays.sorted { lhs, rhs in
            let lhsHasMouse = frames[lhs.displayID]?.contains(mouse) ?? false
            let rhsHasMouse = frames[rhs.displayID]?.contains(mouse) ?? false
            return lhsHasMouse && !rhsHasMouse
        }
        let displays = Array(ordered.prefix(maxScreens))
        guard !displays.isEmpty else { throw CaptureError.noDisplays }

        var captured: [CapturedScreen] = []
        for (offset, display) in displays.enumerated() {
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let width = min(maxWidth, Int(display.width))
            let height = Int((Double(width) * Double(display.height) / Double(display.width)).rounded())
            config.width = width
            config.height = height
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = jpegData(from: image) else { throw CaptureError.encodingFailed }

            let frame = frames[display.displayID] ?? NSScreen.main?.frame ?? .zero
            let description = ScreenDescription(
                index: offset + 1,
                pixelWidth: width,
                pixelHeight: height,
                hasCursor: frame.contains(mouse)
            )
            captured.append(CapturedScreen(
                encoded: EncodedScreen(description: description, jpeg: jpeg),
                appKitFrame: frame
            ))
        }
        return captured
    }

    private static func displayFrames() -> [CGDirectDisplayID: CGRect] {
        var frames: [CGDirectDisplayID: CGRect] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                frames[number] = screen.frame
            }
        }
        return frames
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }
}
