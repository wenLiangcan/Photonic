import Foundation
import Testing
@testable import Photonic

@Suite("Resize layout sequencing")
struct ResizeLayoutTests {
    @Test func resizeKeepsContentCoordinatesStableUntilItFinishes() {
        var layout = ResizeLayoutState()
        let original = CGSize(width: 800, height: 600)
        layout.begin(contentSize: original)
        for width in stride(from: 810, through: 1400, by: 10) {
            #expect(layout.contentSize(for: CGSize(width: width, height: 900)) == original)
        }
        layout.end()
        let final = CGSize(width: 1400, height: 900)
        #expect(layout.contentSize(for: final) == final)
        #expect(!layout.isDeferred)
    }

    @Test func repeatedResizeStartsDoNotReplaceTheOriginalLayout() {
        var layout = ResizeLayoutState()
        let original = CGSize(width: 800, height: 600)
        layout.begin(contentSize: original)
        layout.begin(contentSize: CGSize(width: 1200, height: 800))
        #expect(layout.contentSize(for: CGSize(width: 1400, height: 900)) == original)
        layout.end()
        layout.end()
        let next = CGSize(width: 900, height: 700)
        #expect(layout.contentSize(for: next) == next)
    }

    @Test func subsequentResizeUsesTheLastCompletedSize() {
        var layout = ResizeLayoutState()
        let original = CGSize(width: 800, height: 600)
        let enlarged = CGSize(width: 1400, height: 900)
        layout.begin(contentSize: original)
        layout.end()
        layout.begin(contentSize: enlarged)
        #expect(layout.contentSize(for: original) == enlarged)
        layout.end()
        #expect(layout.contentSize(for: original) == original)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 600), CGSize(width: 800, height: 0)])
    func emptyInitialBoundsDoNotCreateAnInvalidScale(size: CGSize) {
        var layout = ResizeLayoutState()
        layout.begin(contentSize: size)
        #expect(!layout.isDeferred)
        let next = CGSize(width: 800, height: 600)
        #expect(layout.contentSize(for: next) == next)
    }
}
