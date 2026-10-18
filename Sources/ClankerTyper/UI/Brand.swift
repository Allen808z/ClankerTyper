import AppKit
import SwiftUI

/// Colours chosen for this re-creation (inferred from the original's blue companion and dark
/// notch surfaces). No original artwork or fonts are used.
enum Brand {
    static let blue = NSColor(calibratedRed: 0.20, green: 0.46, blue: 1.00, alpha: 1)
    static let surface = Color(white: 0.09).opacity(0.96)
    static let accent = Color(red: 0.20, green: 0.46, blue: 1.00)
    static let muted = Color.white.opacity(0.55)
}
