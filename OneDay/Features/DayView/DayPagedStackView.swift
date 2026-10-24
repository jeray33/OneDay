import SwiftUI
import UIKit

/// Hosts the day page and back cover. Both move together during a flip,
/// while a shared top bar stays fixed above them.
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

    enum Layer {
        case content, back
    }

    @State private var current: Layer = .content
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var pendingLayer: Layer?
    @State private var flipGeneration = 0
    @State private var flipCancelled = false
    @State private var flipBaseline: CGFloat = 0
    @State private var flipDirection: CGFloat = 0
    @State private var previousTranslation: CGFloat = 0
    @State private var contentEdges = ContentScrollEdges()
    @State private var backEdges = ContentScrollEdges()
    @State private var photoCardUnderTopBar = false
    /// Top inset cached while the status bar is visible, matching
    /// `DayMagazineView`, so the fixed buttons line up with the header's
    /// stand-ins even after the preview hides the status bar.
    @State private var stableTopInset: CGFloat = 0

    private func above(_ layer: Layer) -> Layer? {
        layer == .back ? .content : nil
    }

    private func below(_ layer: Layer) -> Layer? {
        layer == .content ? .back : nil
    }

    // Flip tuning: fraction of the screen height that commits a flip.
    private let snapThreshold: CGFloat = 0.2

    /// True while a page flip owns the current drag (recognized and not
    /// cancelled, or committed and animating). While owned, the current
    /// layer's ScrollView is frozen so the scroll view cannot rubber-band
    /// the scrolling photo content away from the fixed background and chrome
    /// (which only follow the flip offset).
    private var flipOwnsDrag: Bool {
        pendingLayer != nil || (isDragging && !flipCancelled)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                backLayer(h: h)
                contentLayer(h: h)
                fixedTopBar(h: h)
            }
            .frame(width: geo.size.width, height: h)
            .environment(\.dayPhotoViewportWidth, geo.size.width)
            .clipped()
            .simultaneousGesture(flipGesture(h: h),
                                 including: model.selected == nil ? .all : .subviews)
        }
        .ignoresSafeArea()
        .onAppear { stableTopInset = topSafeAreaInset() }
    }

    private var topInset: CGFloat {
        stableTopInset > 0 ? stableTopInset : topSafeAreaInset()
    }

    /// The photo preview draws inside the photo page, above its header. While
    /// it is open the header shows its own buttons (beneath the preview) and
    /// the fixed bar steps aside; both switch in the same update.
    private var previewOwnsTopButtons: Bool {
        model.selected != nil
    }

    // MARK: Fixed top bar

    private func fixedTopBar(h: CGFloat) -> some View {
        FixedTopBar(
            flipOffset: dragOffset,
            model: model,
            topInset: topInset,
            photoUnderBar: !photoCardUnderTopBar,
            onClose: onClose,
            layerUnderBar: { offset in layerUnderTopBar(dragOffset: offset, h: h) }
        )
        .modifier(TopButtonVisibility(visible: !previewOwnsTopButtons))
        .zIndex(4)
    }

    /// The topmost visible layer at the buttons' vertical center for a given
    /// flip offset. The buttons take that page's colors.
    private func layerUnderTopBar(dragOffset: CGFloat, h: CGFloat) -> Layer {
        let y = topInset + DayTopBar.topSpacing + DayTopBar.buttonSize / 2
        for layer in [Layer.content, .back] {
            let offset = layerOffset(layer, h: h, dragOffset: dragOffset)
            if y >= offset, y < offset + h {
                return layer
            }
        }
        return current
    }

    /// Animatable so committed and cancelled flip springs deliver the
    /// interpolated offset every frame; otherwise the colors would switch to
    /// the destination page as soon as the spring starts, while the old page
    /// still lies under the buttons.
    private struct FixedTopBar: View, Animatable {
        var flipOffset: CGFloat
        let model: DayViewModel
        let topInset: CGFloat
        /// The day page's photo cover lies under the buttons.
        let photoUnderBar: Bool
        let onClose: () -> Void
        let layerUnderBar: (CGFloat) -> Layer

        var animatableData: CGFloat {
            get { flipOffset }
            set { flipOffset = newValue }
        }

        var body: some View {
            let layer = layerUnderBar(flipOffset)
            DayTopBar(model: model, onClose: onClose, tint: tint(for: layer), topInset: topInset)
                .environment(\.colorScheme, colorScheme(for: layer))
        }

        private func tint(for layer: Layer) -> Color {
            switch layer {
            case .content: return photoUnderBar ? .white : Theme.ink
            case .back: return Theme.ink
            }
        }

        private func colorScheme(for layer: Layer) -> ColorScheme {
            switch layer {
            case .content: return photoUnderBar ? .dark : model.pageColorScheme
            case .back: return model.backCoverColorScheme
            }
        }
    }

    // MARK: Layers

    @ViewBuilder
    private func contentLayer(h: CGFloat) -> some View {
        DayMagazineView(
            model: model,
            dateNamespace: dateNamespace,
            dateIsSource: dateIsSource,
            onClose: onClose,
            prevDate: prevDate,
            nextDate: nextDate,
            onPrevDay: onPrevDay,
            onNextDay: onNextDay,
            navLoading: navLoading,
            scrollEdgesBinding: $contentEdges,
            scrollDisabled: current != .content,
            scrollFrozen: current == .content && flipOwnsDrag,
            showsTopButtons: previewOwnsTopButtons,
            coverDateMatched: coverDateMatched,
            photoCardUnderTopBar: $photoCardUnderTopBar
        )
        .offset(y: layerOffset(.content, h: h, dragOffset: dragOffset))
        .zIndex(2)
    }

    @ViewBuilder
    private func backLayer(h: CGFloat) -> some View {
        DayBackCoverView(
            model: model,
            entries: historyEntries,
            isLoading: historyLoading,
            onSelectHistoryDay: onSelectHistoryDay,
            scrollEdgesBinding: $backEdges,
            scrollDisabled: current != .back || flipOwnsDrag
        )
        .offset(y: layerOffset(.back, h: h, dragOffset: dragOffset))
        .zIndex(1)
    }

    // MARK: Per-layer placement

    private func layerOffset(_ layer: Layer, h: CGFloat, dragOffset: CGFloat) -> CGFloat {
        let placement = BackCoverFlipPlacement.make(
            fromBack: current == .back, offset: dragOffset, height: h)
        return layer == .content ? placement.contentOffset : placement.backOffset
    }

    /// Attached pages must not overshoot: a bounce would open a gap between them.
    private var flipAnimation: Animation { .spring(response: 0.4, dampingFraction: 1) }

    // MARK: Gesture

    private func flipGesture(h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isVerticalEnough(value.translation) else { return }
                if let pendingLayer {
                    flipGeneration += 1
                    finishFlip(to: pendingLayer)
                }
                let translation = value.translation.height
                let firstUpdate = !isDragging
                let movement = translation - previousTranslation
                previousTranslation = translation
                if firstUpdate {
                    isDragging = true
                    flipCancelled = true
                }
                // Reconsider eligibility while scrolling. Use the latest
                // movement, not cumulative translation, to detect reversals.
                if flipDirection == 0, abs(movement) > 1,
                   shouldAllowFlip(for: movement) {
                    flipBaseline = firstUpdate ? 0 : translation
                    flipDirection = movement < 0 ? -1 : 1
                    flipCancelled = false
                }
                if flipDirection == 0 {
                    dragOffset = 0
                } else {
                    // Once owned, keep scrolling frozen until release. Edge
                    // geometry updates must not revoke an accepted flip.
                    let residual = translation - flipBaseline
                    let distance = flipDirection < 0 ? min(residual, 0) : max(residual, 0)
                    dragOffset = distance
                }
            }
            .onEnded { value in
                guard pendingLayer == nil else { return }
                guard isDragging, !flipCancelled else {
                    cancelDrag()
                    return
                }
                let distance = dragOffset
                let velocity = value.predictedEndTranslation.height - value.translation.height
                let threshold = h * snapThreshold
                let flingDown = velocity > 260
                let flingUp = velocity < -260
                if flipDirection < 0, distance < 0,
                   (distance <= -threshold || flingUp), let below = self.below(current) {
                    commitFlip(to: below, target: -h)
                } else if flipDirection > 0, distance > 0,
                          (distance >= threshold || flingDown), let above = self.above(current) {
                    commitFlip(to: above, target: h)
                } else {
                    cancelDrag()
                }
            }
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
        withAnimation(flipAnimation, completionCriteria: .removed) {
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
            flipBaseline = 0
            flipDirection = 0
            previousTranslation = 0
        }
    }

    private func cancelDrag() {
        withAnimation(flipAnimation) {
            dragOffset = 0
        }
        isDragging = false
        flipCancelled = false
        flipBaseline = 0
        flipDirection = 0
        previousTranslation = 0
    }

    /// Decides whether movement on the current layer may flip (rather
    /// than being ceded to the inner scroll view).
    private func shouldAllowFlip(for translation: CGFloat) -> Bool {
        switch current {
        case .back:
            // The history page owns upward drags for scrolling. It can flip
            // back to the photo page only when pulled down from its top edge.
            return translation > 0 && backEdges.atTop
        case .content:
            // Downward pulls stay with the scroll view so the photo can zoom.
            return translation < 0 && contentEdges.atBottom
        }
    }

    private func isVerticalEnough(_ t: CGSize) -> Bool {
        abs(t.height) > abs(t.width) * 1.4 && abs(t.height) > 8
    }
}
