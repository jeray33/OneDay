import SwiftUI

/// Preserve the aligned grid's existing animation, but make waterfall reflows
/// atomic so scroll-anchor corrections use final, not interpolated geometry.
func withDayGridLayoutChange(_ arrangement: DayGridArrangement, _ changes: () -> Void) {
    if arrangement == .waterfall {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    } else {
        withAnimation(.easeInOut(duration: 0.3), changes)
    }
}

/// Measures the same cells in both loading states, including real caption
/// wrapping. Only placement changes; photo order and scroll IDs stay intact.
struct WaterfallLayout: Layout {
    var columnCount: Int
    var columnWidth: CGFloat
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    struct Configuration: Equatable {
        let columns: Int
        let width: CGFloat
        let horizontal: CGFloat
        let vertical: CGFloat
    }

    struct Cache {
        var configuration: Configuration?
        var heights: [CGFloat] = []
        var plan: WaterfallLayoutPolicy.Plan?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        measuredPlan(subviews: subviews, cache: &cache).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let plan = measuredPlan(subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            let frame = plan.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: frame.height)
            )
        }
    }

    private func measuredPlan(subviews: Subviews, cache: inout Cache) -> WaterfallLayoutPolicy.Plan {
        let proposal = ProposedViewSize(width: columnWidth, height: nil)
        let heights = subviews.map { $0.sizeThatFits(proposal).height }
        let configuration = Configuration(
            columns: columnCount, width: columnWidth,
            horizontal: horizontalSpacing, vertical: verticalSpacing
        )
        if cache.configuration == configuration, cache.heights == heights, let plan = cache.plan {
            return plan
        }
        let plan = WaterfallLayoutPolicy.plan(
            heights: heights, columnCount: columnCount, columnWidth: columnWidth,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing
        )
        cache.configuration = configuration
        cache.heights = heights
        cache.plan = plan
        return plan
    }
}

/// Lightweight cells remain laid out off screen so ScrollViewReader can find
/// every photo. Expensive Photos requests exist only near the viewport, with
/// hysteresis: a cell loads its image within one screen of the viewport and
/// stays loaded until it drifts past `WaterfallLayoutPolicy.unloadScreens`
/// screens, so cells sitting at the boundary cannot flip on and off while
/// scrolling slowly. Every layout uses this gate; the grid's lazy toggle only
/// decides whether the aligned grid also materializes cells lazily.
struct ViewportPhotoCell<Content: View>: View {
    let viewportSize: CGSize
    let forceLoad: Bool
    @ViewBuilder var content: (Bool) -> Content

    @State private var isLoaded = false

    var body: some View {
        content(isLoaded || forceLoad)
            .onGeometryChange(for: Bool.self) { geometry in
                WaterfallLayoutPolicy.shouldLoadImage(
                    frame: geometry.frame(in: .named(heroCoordinateSpace)),
                    viewport: CGRect(origin: .zero, size: viewportSize),
                    isLoaded: isLoaded
                )
            } action: { isLoaded = $0 }
    }
}
