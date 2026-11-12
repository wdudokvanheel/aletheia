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

    @MainActor func testCollapsedPaneKeepsPreferredWidth() {
        let split = PaneSplitView(proportional: false, preferredSize: 300)
        split.frame = NSRect(x: 0, y: 0, width: 1001, height: 600)
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.collapsedSize = 28
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 28)
        split.setPosition(350, ofDividerAt: 0)
        split.rememberDividerPosition()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 28)
        XCTAssertEqual(split.preferredSize, 300)
        split.collapsedSize = nil
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 300)
    }

    @MainActor func testFileTreeCollapseIsRestoredFromSession() async {
        let controller = EditorWindow()
        controller.toggleFileTree(nil)
        let state = controller.session
        XCTAssertEqual(state.treeCollapsed, true)
        controller.toggleFileTree(nil)
        XCTAssertNil(controller.session.treeCollapsed)
        let restored = EditorWindow()
        _ = await withCheckedContinuation { continuation in
            restored.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(restored.session.treeCollapsed, true)
        XCTAssertEqual(restored.session.treeWidth, state.treeWidth)
    }
}
