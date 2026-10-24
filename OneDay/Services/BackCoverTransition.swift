import CoreGraphics

nonisolated enum BackCoverTransition: String, CaseIterable, Identifiable {
    case reveal, sync

    static let storageKey = "OneDay.backCoverTransition"
    var id: Self { self }
    var label: String { self == .reveal ? "揭开" : "同步" }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .reveal
    }
}

/// Offsets of the day page and the back cover while moving between them.
/// Committed flips end at an offset of minus the height (day page to back
/// cover) or plus the height (back cover to day page); in both styles those
/// end states equal the destination's rest placement.
nonisolated struct BackCoverFlipPlacement: Equatable {
    var contentOffset: CGFloat
    var backOffset: CGFloat

    /// - Parameters:
    ///   - fromBack: The back cover is the resting page; otherwise the day page is.
    ///   - offset: Flip offset of the resting page. Negative lifts the day
    ///     page toward the back cover; positive pulls the back cover down.
    static func make(transition: BackCoverTransition, fromBack: Bool,
                     offset: CGFloat, height: CGFloat) -> Self {
        let h = height.isFinite ? max(1, height) : 1
        if fromBack {
            let down = min(max(0, offset), h)
            return Self(contentOffset: down - h,
                        backOffset: transition == .sync ? offset : min(0, offset))
        }
        let up = min(max(0, -offset), h)
        return Self(contentOffset: -up, backOffset: transition == .sync ? h - up : 0)
    }
}
