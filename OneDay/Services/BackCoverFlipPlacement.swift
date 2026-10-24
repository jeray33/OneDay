import CoreGraphics

/// Offsets of the day page and the back cover while moving between them.
/// Committed flips end at an offset of minus the height (day page to back
/// cover) or plus the height (back cover to day page); those
/// end states equal the destination's rest placement.
nonisolated struct BackCoverFlipPlacement: Equatable {
    var contentOffset: CGFloat
    var backOffset: CGFloat

    /// - Parameters:
    ///   - fromBack: The back cover is the resting page; otherwise the day page is.
    ///   - offset: Flip offset of the resting page. Negative lifts the day
    ///     page toward the back cover; positive pulls the back cover down.
    static func make(fromBack: Bool, offset: CGFloat, height: CGFloat) -> Self {
        let h = height.isFinite ? max(1, height) : 1
        if fromBack {
            let down = min(max(0, offset), h)
            return Self(contentOffset: down - h,
                        backOffset: offset)
        }
        let up = min(max(0, -offset), h)
        return Self(contentOffset: -up, backOffset: h - up)
    }
}
