import CoreGraphics
import Testing
@testable import ClankerTyper

@Suite("Pointing tag parsing")
struct PointingParserTests {
    @Test func parsesTrailingPointWithLabel() {
        let parsed = PointingParser.parse("Click Save in the toolbar. [POINT:412,88:save button]")
        #expect(parsed.spokenText == "Click Save in the toolbar.")
        #expect(parsed.target == PointTarget(x: 412, y: 88, label: "save button", screenIndex: nil))
    }

    @Test func parsesScreenIndex() {
        let parsed = PointingParser.parse("That's on your other display. [POINT:10,20:mail:screen2]")
        #expect(parsed.target?.screenIndex == 2)
        #expect(parsed.target?.label == "mail")
    }

    @Test func pointWithoutLabel() {
        let parsed = PointingParser.parse("Right there. [POINT:5,6]")
        #expect(parsed.target == PointTarget(x: 5, y: 6, label: nil, screenIndex: nil))
    }

    @Test func pointNoneHasNoTarget() {
        let parsed = PointingParser.parse("Nothing on screen needs pointing. [POINT:none]")
        #expect(parsed.target == nil)
        #expect(parsed.spokenText == "Nothing on screen needs pointing.")
    }

    @Test func noTagLeavesTextTrimmed() {
        let parsed = PointingParser.parse("  Just an answer.  ")
        #expect(parsed.target == nil)
        #expect(parsed.spokenText == "Just an answer.")
    }

    @Test func tagInMiddleIsNotATarget() {
        let parsed = PointingParser.parse("See [POINT:1,2:x] for details, then continue.")
        #expect(parsed.target == nil)
    }
}

@Suite("Screenshot to screen coordinates")
struct PointMappingTests {
    @Test func topLeftPixelMapsToTopLeftOfDisplay() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let p = PointMapping.screenPoint(x: 0, y: 0, imageSize: CGSize(width: 1280, height: 800), displayFrame: frame)
        #expect(abs(p.x - 0) < 0.001)
        #expect(abs(p.y - 900) < 0.001)
    }

    @Test func centerMapsWithSecondaryDisplayOffset() {
        let frame = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let p = PointMapping.screenPoint(x: 640, y: 400, imageSize: CGSize(width: 1280, height: 720), displayFrame: frame)
        #expect(abs(p.x - (1440 + 960)) < 0.001)
        #expect(abs(p.y - (frame.maxY - 600)) < 0.001)  // 400 px * 1.5 pt/px down from the top
    }

    @Test func clampsOutOfRangeCoordinates() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let p = PointMapping.screenPoint(x: 5000, y: -50, imageSize: CGSize(width: 100, height: 100), displayFrame: frame)
        #expect(abs(p.x - 100) < 0.001)
        #expect(abs(p.y - 100) < 0.001)
    }
}

@Suite("Companion motion")
struct CompanionMotionTests {
    @Test func flightArrivesThenHoldsThenReturns() {
        var motion = CompanionMotion()
        motion.update(now: 0, mouse: CGPoint(x: 100, y: 100))
        motion.point(at: CGPoint(x: 500, y: 500), label: "go", now: 0)

        motion.update(now: CompanionMotion.flightDuration + 0.01, mouse: CGPoint(x: 100, y: 100))
        #expect(abs(motion.position.x - 500) < 0.5)
        #expect(motion.label == "go")

        motion.update(now: CompanionMotion.flightDuration + CompanionMotion.pointHold + 0.1,
                      mouse: CGPoint(x: 100, y: 100))
        #expect(motion.label == nil)
        #expect(motion.mode == .following)
    }
}
