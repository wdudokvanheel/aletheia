import AppKit
import XCTest
@testable import Aletheia

final class PaneSplitViewTests: XCTestCase {
    @MainActor func testFixedWidthAndRatioSurviveResizingAndTemporaryClamping() {
        for proportional in [false, true] {
            let preferred: CGFloat = proportional ? 0.4 : 300
            let split = PaneSplitView(proportional: proportional, preferredSize: preferred)
            split.frame = NSRect(x: 0, y: 0, width: 1001, height: 600)
            split.addArrangedSubview(NSView())
            split.addArrangedSubview(NSView())
            split.applyPreferredSize()
            for width: CGFloat in [1401, 300, 1001] {
                split.setFrameSize(NSSize(width: width, height: 600))
                XCTAssertEqual(split.preferredSize, preferred, accuracy: 0.001)
                if width > 300 {
                    XCTAssertEqual(split.arrangedSubviews[0].frame.width,
                                   proportional ? (width - split.dividerThickness) * preferred : preferred,
                                   accuracy: 1)
                }
            }
            split.setPosition(350, ofDividerAt: 0)
            split.rememberDividerPosition()
            XCTAssertEqual(split.preferredSize, proportional ? 350 / (1001 - split.dividerThickness) : 350,
                           accuracy: 0.001)
        }
    }
}
