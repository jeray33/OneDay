import SwiftUI

/// Only this fixed-size text animates, never the card or its parent grid.
struct PlaceLoadingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if isVisible && scenePhase == .active && !reduceMotion {
                Text(PlaceNaming.loadingTitle)
                    .phaseAnimator([false, true]) { content, bright in
                        content.opacity(bright ? 0.85 : 0.4)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
            } else {
                Text(PlaceNaming.loadingTitle).opacity(0.5)
            }
        }
        .accessibilityLabel("正在加载地点")
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
    }
}
