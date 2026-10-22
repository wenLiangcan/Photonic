import Foundation
import Testing
@testable import Photonic

@Suite("Independent viewer windows")
@MainActor
struct ViewerWindowTests {
    @Test func openingNavigatingAndClosingOneViewerPreservesTheOther() {
        // Nonexistent fixture paths avoid filesystem writes and desktop effects.
        let directory = URL(fileURLWithPath: "/photonic-nonexistent-test-fixtures")
        let first = ViewerStore()
        let second = ViewerStore()
        first.open(urls: [directory.appendingPathComponent("a.jpg"), directory.appendingPathComponent("b.jpg")])
        first.rotateClockwise()
        let original = first.currentItem
        second.open(urls: [directory.appendingPathComponent("c.jpg"), directory.appendingPathComponent("d.jpg")])
        second.next()
        second.setViewMode(.waterfall)
        #expect(first.currentItem == original)
        #expect(first.rotationQuarterTurns == 1)
        #expect(first.viewMode == .single)
        second.closeImage()
        #expect(first.currentItem == original)
        #expect(first.items.count == 2)
        #expect(second.currentItem == nil)
    }
}
