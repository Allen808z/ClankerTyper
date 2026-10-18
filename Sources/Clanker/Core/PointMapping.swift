import CoreGraphics

/// Maps a point in a screenshot (top-left origin, pixel space) onto AppKit screen
/// coordinates (bottom-left origin, points) for the display it was captured from.
enum PointMapping {
    static func screenPoint(x: Double, y: Double, imageSize: CGSize, displayFrame: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGPoint(x: displayFrame.midX, y: displayFrame.midY)
        }
        // Clamp to the image so a slightly-off model coordinate still lands on screen.
        let px = min(max(x, 0), Double(imageSize.width))
        let py = min(max(y, 0), Double(imageSize.height))
        let scaleX = displayFrame.width / imageSize.width
        let scaleY = displayFrame.height / imageSize.height
        return CGPoint(
            x: displayFrame.minX + CGFloat(px) * scaleX,
            y: displayFrame.maxY - CGFloat(py) * scaleY
        )
    }
}
