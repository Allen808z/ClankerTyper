import AppKit

/// Motion model for the companion cursor. Pure state + math so it is testable; the view
/// layer only reads `position` and `label` each frame.
struct CompanionMotion {
    enum Mode: Equatable {
        case following
        case listening
        case flying(from: CGPoint, to: CGPoint, start: TimeInterval, duration: TimeInterval)
        case pointing(at: CGPoint, until: TimeInterval)
    }

    static let followOffset = CGSize(width: 18, height: -18)
    static let flightDuration: TimeInterval = 0.7
    static let pointHold: TimeInterval = 4.0

    private(set) var mode: Mode = .following
    private(set) var position: CGPoint = .zero
    private(set) var label: String?

    /// Advances the companion. `mouse` is the current pointer location in AppKit coordinates.
    mutating func update(now: TimeInterval, mouse: CGPoint) {
        let follow = CGPoint(x: mouse.x + Self.followOffset.width, y: mouse.y + Self.followOffset.height)
        switch mode {
        case .following:
            position = follow
        case .listening:
            position = follow
        case let .flying(from, to, start, duration):
            let t = min(max((now - start) / duration, 0), 1)
            position = Self.arc(from: from, to: to, t: Self.easeInOut(t))
            if t >= 1 {
                mode = .pointing(at: to, until: now + Self.pointHold)
            }
        case let .pointing(at, until):
            position = at
            if now >= until {
                mode = .following
                label = nil
            }
        }
    }

    mutating func setListening(_ listening: Bool) {
        if listening {
            mode = .listening
        } else if mode == .listening {
            mode = .following
        }
    }

    /// Starts a flight to a target. The label stays on screen until the companion returns.
    mutating func point(at target: CGPoint, label: String?, now: TimeInterval) {
        self.label = label
        mode = .flying(from: position, to: target, start: now, duration: Self.flightDuration)
    }

    mutating func cancelPointing() {
        label = nil
        mode = .following
    }

    /// Quadratic arc that lifts above the straight line between the two points.
    static func arc(from: CGPoint, to: CGPoint, t: Double) -> CGPoint {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let distance = hypot(to.x - from.x, to.y - from.y)
        let control = CGPoint(x: mid.x, y: mid.y + min(distance * 0.25, 120))
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        return CGPoint(x: x, y: y)
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

/// Draws the companion on every display. Each screen gets a transparent, click-through window.
@MainActor
final class CursorOverlay {
    private var windows: [OverlayWindow] = []
    private var timer: Timer?
    private var motion = CompanionMotion()
    private(set) var isVisible = true
    private var liveText = ""
    private var recordingLabel = "REC"
    private var busyLabel: String?
    private var screenObserver: NSObjectProtocol?

    func start() {
        rebuildWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Live caption shown in the REC pill while the shortcut is held.
    func setLiveText(_ text: String) {
        liveText = text
    }

    /// Shows a bubble above the pointer with a blue dot while the local model works on text.
    /// Pass nil to hide it.
    func showBusy(_ label: String?) {
        busyLabel = label
    }

    /// Header of the recording bubble: "REC" while holding, "HANDS-FREE" in hands-free mode.
    func setRecordingLabel(_ label: String) {
        recordingLabel = label
    }

    /// Shows or hides the blue companion only. The overlay windows stay up so the REC pill still
    /// appears while the shortcut is held.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        windows.forEach { $0.orderFrontRegardless() }
    }

    func setListening(_ listening: Bool) {
        motion.setListening(listening)
    }

    /// Flies the companion to a screen point (AppKit coordinates) and shows a label there.
    func point(at target: CGPoint, label: String?) {
        motion.point(at: target, label: label, now: CACurrentMediaTime())
    }

    func cancelPointing() {
        motion.cancelPointing()
    }

    private func tick() {
        motion.update(now: CACurrentMediaTime(), mouse: NSEvent.mouseLocation)
        let mouse = NSEvent.mouseLocation
        for window in windows {
            window.companionView.position = motion.position
            window.companionView.label = motion.label
            window.companionView.listening = motion.mode == .listening
            window.companionView.mouse = mouse
            window.companionView.companionVisible = isVisible
            window.companionView.liveText = liveText
            window.companionView.recordingLabel = recordingLabel
            window.companionView.busyLabel = busyLabel
            window.companionView.needsDisplay = true
        }
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.orderFrontRegardless()
            return window
        }
        setVisible(isVisible)
    }
}

/// Borderless, transparent, click-through window covering one screen.
final class OverlayWindow: NSWindow {
    let companionView: CompanionView

    init(screen: NSScreen) {
        companionView = CompanionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Use the four-argument initializer: AppKit's five-argument `screen:` variant calls back
        // into this four-argument one, which traps for subclasses that do not override it.
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = companionView
        companionView.screenOrigin = screen.frame.origin
        companionView.screenFrame = screen.frame
        setFrame(screen.frame, display: false)
    }
}

/// Paints the blue companion triangle and, when pointing, its label bubble.
final class CompanionView: NSView {
    var position: CGPoint = .zero
    var label: String?
    var listening = false
    var screenOrigin: CGPoint = .zero
    var screenFrame: CGRect = .zero
    /// Pointer location in AppKit coordinates; the recording pill sits above it.
    var mouse: CGPoint = .zero
    /// Off when the user hides the companion; the REC pill is still drawn.
    var companionVisible = true
    /// Partial transcript shown next to the REC dot.
    var liveText = ""
    var recordingLabel = "REC"
    /// When set, the bubble shows this label with a blue dot instead of recording.
    var busyLabel: String?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        drawRecordingPill()

        // Only the display that holds the companion draws it, so it never appears twice.
        guard companionVisible, screenFrame.contains(position) else { return }

        let local = CGPoint(x: position.x - screenOrigin.x, y: position.y - screenOrigin.y)
        let tip = local

        // Arrow-shaped cursor: tip at `local`, body extends down and right.
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: CGPoint(x: tip.x + 4, y: tip.y - 20))
        arrow.line(to: CGPoint(x: tip.x + 9, y: tip.y - 13))
        arrow.line(to: CGPoint(x: tip.x + 16, y: tip.y - 13))
        arrow.close()
        Brand.blue.setFill()
        arrow.fill()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.5
        arrow.stroke()

        if let label, !label.isEmpty {
            drawLabel(label, near: tip)
        }
    }

    /// Recording bubble above the pointer while the shortcut is held: a REC header and the whole
    /// transcript so far, wrapped over as many lines as it needs (newest text at the bottom).
    private func drawRecordingPill() {
        let busy = !listening && busyLabel != nil
        guard listening || busy, screenFrame.contains(mouse) else { return }
        let anchor = CGPoint(x: mouse.x - screenOrigin.x, y: mouse.y - screenOrigin.y)
        let liveText = busy ? "" : self.liveText

        let rec = NSAttributedString(string: busy ? busyLabel! : recordingLabel, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let captionFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont,
            .foregroundColor: NSColor.white,
        ]
        let maxTextWidth: CGFloat = min(440, bounds.width - 40)
        let caption = NSAttributedString(string: liveText, attributes: captionAttributes)
        let captionRect = caption.boundingRect(
            with: NSSize(width: maxTextWidth, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let headerHeight: CGFloat = 22
        let bodyHeight = liveText.isEmpty ? 0 : ceil(captionRect.height) + 10
        let width = max(rec.size().width + 40, min(maxTextWidth + 20, ceil(captionRect.width) + 20))
        let height = headerHeight + bodyHeight

        // Keep the bubble on screen near the right and top edges.
        let x = min(max(anchor.x - 28, 6), bounds.width - width - 6)
        let y = min(anchor.y + 18, bounds.height - height - 6)
        let bubble = NSRect(x: x, y: y, width: width, height: height)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12).fill()

        // Pulse the dot so it reads as live, not as a static badge.
        let pulse = 0.55 + 0.45 * (sin(CACurrentMediaTime() * 6) + 1) / 2
        (busy ? Brand.blue : NSColor.systemRed).withAlphaComponent(CGFloat(pulse)).setFill()
        let headerY = bubble.maxY - headerHeight / 2
        NSBezierPath(ovalIn: NSRect(x: bubble.minX + 10, y: headerY - 4, width: 8, height: 8)).fill()
        rec.draw(at: CGPoint(x: bubble.minX + 23, y: headerY - rec.size().height / 2))

        if !liveText.isEmpty {
            let textRect = NSRect(
                x: bubble.minX + 10,
                y: bubble.minY + 6,
                width: width - 20,
                height: bodyHeight - 10
            )
            caption.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func drawLabel(_ text: String, near tip: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding = CGSize(width: 10, height: 6)
        let box = NSRect(
            x: tip.x + 24,
            y: tip.y - 18 - textSize.height - padding.height * 2,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        let bubble = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor(white: 0.08, alpha: 0.92).setFill()
        bubble.fill()
        Brand.blue.setStroke()
        bubble.lineWidth = 1.5
        bubble.stroke()
        string.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
