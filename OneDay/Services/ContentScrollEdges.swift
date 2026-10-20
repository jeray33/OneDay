import CoreGraphics

/// Vertical edge state used to hand scrolling over to cover/back-cover paging.
nonisolated struct ContentScrollEdges: Equatable {
    var atTop: Bool = true
    var atBottom: Bool = false

    init(atTop: Bool = true, atBottom: Bool = false) {
        self.atTop = atTop
        self.atBottom = atBottom
    }

    /// Both rectangles must use the same coordinate space. Actual content
    /// bounds avoid assumptions about ScrollView safe-area bars and insets.
    init(contentBounds: CGRect, viewportBounds: CGRect) {
        guard viewportBounds.height > 0,
              !contentBounds.isNull, !viewportBounds.isNull else {
            self.init(atTop: false, atBottom: false)
            return
        }
        self.init(
            atTop: contentBounds.minY >= viewportBounds.minY - 1,
            atBottom: contentBounds.maxY <= viewportBounds.maxY + 1
        )
    }
}
