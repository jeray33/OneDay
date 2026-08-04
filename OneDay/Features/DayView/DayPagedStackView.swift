import SwiftUI
import UIKit

/// Hosts the three full-screen layers (cover / content / back) in a fixed
/// z-stack and drives vertical drag-to-flip transitions between them.
///
/// Layer order (bottom → top): back, content, cover. The active layer follows
/// the finger; the layer beneath slides up into place from below; the layer
/// above (when going back) drops down from the top.
struct DayPagedStackView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID
    var dateIsSource: Bool
    var coverDateMatched: Bool = true
    var onClose: () -> Void
    var historyEntries: [TodayInHistoryEntry]
    var historyLoading: Bool
    var onSelectHistoryDay: ((Date) -> Void)? = nil
    var prevDate: Date?
    var nextDate: Date?
    var onPrevDay: (() -> Void)?
    var onNextDay: (() -> Void)?
    var navLoading: Bool = false

    enum Layer: Int, CaseIterable {
        case cover = 0, content = 1, back = 2
        var above: Layer? { Layer(rawValue: rawValue - 1) }
        var below: Layer? { Layer(rawValue: rawValue + 1) }
    }

    @State private var current: Layer = .cover
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var pendingLayer: Layer?
    @State private var flipGeneration = 0
    @State private var flipCancelled = false
    @State private var continuousHandoffTranslation: CGFloat?
    @State private var continuousFlipDirection: CGFloat = 0
    @State private var contentEdges = ContentScrollEdges()
    @State private var backEdges = ContentScrollEdges()

    // Transition tuning. `activeFade`/`activeShrink` are aligned with the
    // beneath/above start opacity & scale so that when a flip commits (the
    // active layer becomes the adjacent layer) there is no visual jump.
    private let snapThreshold: CGFloat = 0.2
    // Continuous handoff should feel like one scrolling gesture rather than
    // requiring a second full page drag after reaching the content edge.
    private let continuousSnapThreshold: CGFloat = 0.09 //越小越容易完成翻页
    private let continuousDragGain: CGFloat = 1.45 //越大越灵敏、省力；越小越跟手、沉稳
    private let continuousFlingVelocity: CGFloat = 180
    private let peekGap: CGFloat = 0.06      // beneath-layer peek (fraction of height)
    private let beneathStartScale: CGFloat = 0.92
    private let beneathStartOpacity: CGFloat = 0.7
    private var activeFade: CGFloat { 1 - beneathStartOpacity }   // 0.30
    private var activeShrink: CGFloat { 1 - beneathStartScale }   // 0.08

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                backLayer(h: h)
                contentLayer(h: h)
                coverLayer(h: h)
            }
            .frame(width: geo.size.width, height: h)
            .clipped()
            .simultaneousGesture(flipGesture(h: h),
                                 including: model.selected == nil ? .all : .subviews)
        }
        .ignoresSafeArea()
    }

    // MARK: Layers

    @ViewBuilder
    private func coverLayer(h: CGFloat) -> some View {
        let p = layerProgress(.cover, h: h)
        DayCoverView(model: model,
                     dateNamespace: coverDateMatched ? dateNamespace : nil,
                     dateIsSource: dateIsSource,
                     onClose: onClose)
            .rotationEffect(.degrees(p.rotation))
            .offset(x: p.offsetX, y: p.offsetY)
            .scaleEffect(p.scale, anchor: .center)
            .opacity(p.opacity)
            .zIndex(3)
    }

    @ViewBuilder
    private func contentLayer(h: CGFloat) -> some View {
        let p = layerProgress(.content, h: h)
        DayMagazineView(
            model: model,
            dateNamespace: dateNamespace,
            dateIsSource: dateIsSource,
            contentRevealed: current == .content || p.opacity > 0.05,
            onClose: onClose,
            prevDate: prevDate,
            nextDate: nextDate,
            onPrevDay: onPrevDay,
            onNextDay: onNextDay,
            navLoading: navLoading,
            scrollEdgesBinding: $contentEdges,
            scrollDisabled: current != .content
        )
        .rotationEffect(.degrees(p.rotation))
        .offset(x: p.offsetX, y: p.offsetY)
        .scaleEffect(p.scale, anchor: .center)
        .opacity(p.opacity)
        .zIndex(2)
    }

    @ViewBuilder
    private func backLayer(h: CGFloat) -> some View {
        let p = layerProgress(.back, h: h)
        DayBackCoverView(
            model: model,
            entries: historyEntries,
            isLoading: historyLoading,
            onSelectHistoryDay: onSelectHistoryDay,
            onClose: onClose,
            scrollEdgesBinding: $backEdges,
            scrollDisabled: current != .back
        )
        .rotationEffect(.degrees(p.rotation))
        .offset(x: p.offsetX, y: p.offsetY)
        .scaleEffect(p.scale, anchor: .center)
        .opacity(p.opacity)
        .zIndex(1)
    }

    // MARK: Per-layer transform

    private struct LayerTransform {
        var offsetX: CGFloat = 0
        var offsetY: CGFloat
        var rotation: Double = 0
        var scale: CGFloat
        var opacity: Double
    }

    /// Computes the current transform for a given layer based on `current`,
    /// `dragOffset`, and the flip mode.
    private func layerProgress(_ layer: Layer, h: CGFloat) -> LayerTransform {
        let staggered = model.pageFlipMode == .staggeredPhysics
            || model.pageFlipMode == .continuousStaggered
        let free = model.pageFlipMode == .freePhysics || staggered
        let gap: CGFloat = free ? 0 : peekGap
        let staggerX: CGFloat = -60
        let staggerRotation = 3.0 //旋转角度-3.0
        let staggerTopLift: CGFloat = staggered && model.staggeredTopLiftEnabled ? 10 : 0

        if layer == current {
            // While flipping backward, the page above drops over the current
            // page. Keep this lower page parked (free mode), or move it only
            // into the subtle recessed resting pose used by the stack.
            if dragOffset > 0, current.above != nil {
                let down = min(dragOffset / h, 1)
                if free {
                    return LayerTransform(offsetY: 0, scale: 1, opacity: 1)
                }
                return LayerTransform(
                    offsetY: h * gap * down,
                    scale: 1 - activeShrink * down,
                    opacity: 1 - Double(activeFade) * Double(down)
                )
            }

            // Active layer follows the finger.
            let total = abs(dragOffset) / h
            let off = rubber(dragOffset, h: h)
            if free {
                // Rigid plate: no fade/shrink, just translation.
                let progress = min(max(0, -dragOffset) / h, 1)
                return LayerTransform(
                    offsetX: staggered ? staggerX * progress : 0,
                    offsetY: off - staggerTopLift * progress,
                    rotation: staggered ? staggerRotation * Double(progress) : 0,
                    scale: 1,
                    opacity: 1
                )
            }
            return LayerTransform(
                offsetY: off,
                scale: 1 - activeShrink * min(total, 1),
                opacity: 1 - Double(activeFade) * Double(min(total, 1))
            )
        }

        if layer == current.below {
            // Beneath: starts below the screen, slides up into place as we swipe up.
            let up = max(0, -dragOffset) / h
            let startOffset = h * gap
            let off = startOffset * (1 - min(up, 1))
            if free {
                return LayerTransform(offsetY: off, scale: 1, opacity: 1)
            }
            return LayerTransform(
                offsetY: off,
                scale: beneathStartScale + (1 - beneathStartScale) * min(up, 1),
                opacity: Double(beneathStartOpacity) + Double(1 - beneathStartOpacity) * Double(min(up, 1))
            )
        }

        if layer == current.above {
            // Above: fully off-screen at rest (it sits on top in z-order, so any
            // peek would bleed over the active layer), drops in as we swipe down.
            let down = max(0, dragOffset) / h
            let startOffset = -h - staggerTopLift
            let off = startOffset * (1 - min(down, 1))
            if free {
                let resting = 1 - min(down, 1)
                return LayerTransform(
                    offsetX: staggered ? staggerX * resting : 0,
                    offsetY: off,
                    rotation: staggered ? staggerRotation * Double(resting) : 0,
                    scale: 1,
                    opacity: 1
                )
            }
            return LayerTransform(
                offsetY: off,
                scale: beneathStartScale + (1 - beneathStartScale) * min(down, 1),
                opacity: Double(beneathStartOpacity) + Double(1 - beneathStartOpacity) * Double(min(down, 1))
            )
        }

        // Non-adjacent layer: park far off-screen, fully hidden.
        if layer.rawValue < current.rawValue {
            return LayerTransform(offsetY: -h * 2, scale: 1, opacity: 0)
        } else {
            return LayerTransform(offsetY: h * 2, scale: 1, opacity: 0)
        }
    }

    /// Rubber-band resistance when dragging past an edge that has no layer.
    private func rubber(_ value: CGFloat, h: CGFloat) -> CGFloat {
        if current == .cover && value > 0 {
            return value * 0.35     // no layer above cover
        }
        if current == .back && value < 0 {
            return value * 0.35     // no layer below back
        }
        return value
    }

    // MARK: Gesture

    private func flipGesture(h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isVerticalEnough(value.translation) else { return }
                if let pendingLayer {
                    flipGeneration += 1
                    finishFlip(to: pendingLayer)
                }
                if current == .content,
                   model.pageFlipMode == .continuousStaggered {
                    updateContinuousContentDrag(value.translation.height, h: h)
                    return
                }
                if !isDragging {
                    isDragging = true
                    flipCancelled = !shouldAllowFlip(for: value.translation.height)
                }
                if !flipCancelled,
                   !shouldAllowFlip(for: value.translation.height) {
                    flipCancelled = true
                }
                if flipCancelled {
                    dragOffset = 0
                } else {
                    dragOffset = constrained(value.translation.height, h: h)
                }
            }
            .onEnded { value in
                guard pendingLayer == nil else { return }
                if current == .content,
                   model.pageFlipMode == .continuousStaggered {
                    endContinuousContentDrag(value, h: h)
                    return
                }
                guard isDragging, !flipCancelled else {
                    cancelDrag()
                    return
                }
                let distance = value.translation.height
                let velocity = value.predictedEndTranslation.height - distance
                let threshold = h * snapThreshold
                let flingDown = velocity > 260
                let flingUp = velocity < -260
                if (distance <= -threshold || flingUp), let below = current.below {
                    commitFlip(to: below, target: -h)
                } else if (distance >= threshold || flingDown), let above = current.above {
                    commitFlip(to: above, target: h)
                } else {
                    cancelDrag()
                }
            }
    }

    /// Lets the inner ScrollView consume a drag first, then transfers the
    /// unconsumed distance to page flipping when that same drag reaches an edge.
    private func updateContinuousContentDrag(_ translation: CGFloat, h: CGFloat) {
        guard !model.isDragEnabled else {
            isDragging = true
            flipCancelled = true
            dragOffset = 0
            return
        }

        let direction: CGFloat = translation < 0 ? -1 : 1
        let firstUpdate = !isDragging
        if firstUpdate {
            isDragging = true
            flipCancelled = false
        }

        if continuousFlipDirection != 0,
           continuousFlipDirection != direction {
            clearContinuousHandoff()
            dragOffset = 0
        }

        if continuousHandoffTranslation == nil {
            let reachedEdge = direction < 0 ? contentEdges.atBottom : contentEdges.atTop
            guard reachedEdge else {
                dragOffset = 0
                return
            }
            continuousFlipDirection = direction
            continuousHandoffTranslation = firstUpdate ? 0 : translation
        }

        guard let handoff = continuousHandoffTranslation else { return }
        let residual = translation - handoff
        if continuousFlipDirection < 0 {
            guard residual <= 0 else {
                clearContinuousHandoff()
                dragOffset = 0
                return
            }
            dragOffset = constrained(residual * continuousDragGain, h: h)
        } else {
            guard residual >= 0 else {
                clearContinuousHandoff()
                dragOffset = 0
                return
            }
            dragOffset = constrained(residual * continuousDragGain, h: h)
        }
    }

    private func endContinuousContentDrag(_ value: DragGesture.Value, h: CGFloat) {
        guard continuousHandoffTranslation != nil else {
            isDragging = false
            flipCancelled = false
            clearContinuousHandoff()
            return
        }

        let distance = dragOffset
        let velocity = value.predictedEndTranslation.height - value.translation.height
        let threshold = h * continuousSnapThreshold
        let flingDown = velocity > continuousFlingVelocity
        let flingUp = velocity < -continuousFlingVelocity
        let direction = continuousFlipDirection
        clearContinuousHandoff()

        if direction < 0,
           (distance <= -threshold || flingUp),
           let below = current.below {
            commitFlip(to: below, target: -h)
        } else if direction > 0,
                  (distance >= threshold || flingDown),
                  let above = current.above {
            commitFlip(to: above, target: h)
        } else {
            cancelDrag()
        }
    }

    private func clearContinuousHandoff() {
        continuousHandoffTranslation = nil
        continuousFlipDirection = 0
    }

    /// Animates the active layer fully off-screen to the flip target, then
    /// swaps `current` and zeroes the offset. Because the adjacent layer's
    /// rest transform equals its position at the target offset, the swap is
    /// seamless (no jump).
    private func commitFlip(to layer: Layer, target: CGFloat) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        flipGeneration += 1
        let generation = flipGeneration
        pendingLayer = layer
        withAnimation(.spring(response: 0.4, dampingFraction: 0.84), completionCriteria: .removed) {
            dragOffset = target
        } completion: {
            guard generation == flipGeneration else { return }
            finishFlip(to: layer)
        }
    }

    private func finishFlip(to layer: Layer) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            current = layer
            dragOffset = 0
            isDragging = false
            pendingLayer = nil
            flipCancelled = false
            clearContinuousHandoff()
        }
    }

    private func cancelDrag() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            dragOffset = 0
        }
        isDragging = false
        flipCancelled = false
        clearContinuousHandoff()
    }

    /// Decides whether a drag starting on the current layer may flip (rather
    /// than being ceded to the inner scroll view or photo-drag mode).
    private func shouldAllowFlip(for translation: CGFloat) -> Bool {
        switch current {
        case .cover:
            return true
        case .back:
            // The history page owns upward drags for scrolling. It can flip
            // back to the photo page only when pulled down from its top edge.
            return translation > 0 && backEdges.atTop
        case .content:
            // When free-canvas photo arrangement is on, vertical drags move
            // photos, not layers.
            if model.isDragEnabled { return false }
            // Only flip when the content scroll is pinned to the relevant edge.
            if translation < 0 { return contentEdges.atBottom }   // swipe up → back
            if translation > 0 { return contentEdges.atTop }      // swipe down → cover
            return false
        }
    }

    private func constrained(_ value: CGFloat, h: CGFloat) -> CGFloat {
        if current == .cover && value > 0 { return value * 0.35 }
        if current == .back && value < 0 { return value * 0.35 }
        return value
    }

    private func isVerticalEnough(_ t: CGSize) -> Bool {
        abs(t.height) > abs(t.width) * 1.4 && abs(t.height) > 8
    }
}
