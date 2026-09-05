import Foundation

/// Keeps the content's coordinate space stable while its window changes size.
/// Independent of AppKit so resize sequencing can be tested without a desktop.
struct ResizeLayoutState {
    private(set) var frozenContentSize: CGSize?
    var isDeferred: Bool { frozenContentSize != nil }

    mutating func begin(contentSize: CGSize) {
        guard !isDeferred, contentSize.width > 0, contentSize.height > 0 else { return }
        frozenContentSize = contentSize
    }

    mutating func end() {
        frozenContentSize = nil
    }

    func contentSize(for frameSize: CGSize) -> CGSize {
        frozenContentSize ?? frameSize
    }
}
