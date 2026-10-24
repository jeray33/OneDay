import Observation
import SwiftUI
import UIKit

// MARK: - Shared scrubber state

/// Per-frame scrubber state shared by the day page and its bottom toolbar.
///
/// A mutable reference type (like `HeroFrameStore`) so the very frequent
/// scroll-driven updates mutate it in place without invalidating the large
/// magazine grid body. The day page writes raw inputs from preferences and
/// scroll-geometry callbacks; the toolbar reads `metrics`, `markFractions`
/// and `isScrubbing`.
@MainActor
@Observable
final class DayScrubberState {
    /// True while the user's finger is on the scrubber track.
    var isScrubbing = false

    /// Long-mark fractions (0…1) for section starts, sorted ascending.
    private(set) var markFractions: [CGFloat] = []

    /// Content bounds of the latest layout, in screen space. Also read by
    /// the day page for edge math; used here to calibrate the rest position.
    var contentBounds: CGRect?

    /// Content-top position in the scroll coordinate space, this frame.
    private var contentTopY: CGFloat?
    /// Content-top position captured while the content rests at its top
    /// edge — the anchor scrolled distance is measured against.
    private var restContentTopY: CGFloat?
    /// Latest content offset in the scroll view's own offset space.
    private var rawOffset: CGFloat = 0
    /// Total scrollable distance (content height minus the visible window).
    private var scrollableDistance: CGFloat = 0
    /// Section-top positions below the content top, in content space.
    private var sectionTops: [CGFloat] = []

    /// Offset-space metrics snapshot; safe to drive `scrollTo(y:)` with.
    var metrics: DayScrubberMetrics {
        DayScrubberMetrics(offset: rawOffset,
                           scrolledDistance: scrolledDistance,
                           scrollableDistance: scrollableDistance)
    }

    private var scrolledDistance: CGFloat {
        guard let rest = restContentTopY, let top = contentTopY else { return 0 }
        return rest - top
    }

    // MARK: Inputs (driven by the day page's scroll tracking)

    /// Latest content offset in `scrollTo(y:)` space (0 at the top rest,
    /// content insets excluded). Targets are this plus a delta, so an offset
    /// that included the insets would land every jump short by the inset.
    func updateRawOffset(_ offset: CGFloat) {
        if offset != rawOffset { rawOffset = offset }
    }

    /// Latest content-top position plus viewport geometry, per layout frame.
    func updateContentTop(_ y: CGFloat, viewportTop: CGFloat, viewportHeight: CGFloat) {
        if y != contentTopY { contentTopY = y }
        if let bounds = contentBounds {
            // Recalibrate the rest anchor whenever the content sits at its
            // top edge; bounce overshoots are overwritten once it settles.
            if bounds.minY >= viewportTop - 1 { restContentTopY = y }
            setScrollableDistance(max(0, bounds.height - viewportHeight))
        }
    }

    /// Section-top positions in content space, per relayout.
    func updateSectionTops(_ distances: [CGFloat]) {
        guard distances != sectionTops else { return }
        sectionTops = distances
        recomputeMarkFractions()
    }

    private func setScrollableDistance(_ distance: CGFloat) {
        guard distance != scrollableDistance else { return }
        scrollableDistance = distance
        recomputeMarkFractions()
    }

    private func recomputeMarkFractions() {
        let fractions = DayScrubberPolicy.markFractions(
            sectionDistances: sectionTops,
            scrollableDistance: scrollableDistance
        )
        if fractions != markFractions { markFractions = fractions }
    }
}

// MARK: - Toolbar

/// Bottom chrome of the day content page: small previous-day / next-day
/// glass buttons flanking a slider-style quick-scroll track whose ticks
/// stay fixed while dragging jumps the page to the touched position.
struct DayBottomToolbar: View {
    var state: DayScrubberState
    var prevDate: Date?
    var nextDate: Date?
    var navLoading: Bool
    /// Whether the page is interactive (no photo drag, pinch, or preview).
    var enabled: Bool
    /// Section starts drawn as taller ticks, with a stronger haptic and a
    /// magnetic detent while scrubbing.
    var showsSectionMarks: Bool
    /// Light haptic when scrubbing across ordinary ticks.
    var tickHapticsEnabled: Bool
    var onPrevDay: () -> Void
    var onNextDay: () -> Void
    /// Reports a scrub target; `animated` is true for a single tap jump.
    var onScrub: (_ progress: CGFloat, _ animated: Bool) -> Void

    @State private var lastFingerProgress: CGFloat?
    @State private var lastScrubTarget: CGFloat?
    /// Index into the current marks of the section tick holding the finger.
    @State private var detent: Int?
    /// Touches ignored for this stroke: started on the bottom strip nearest
    /// the home indicator, or moved steeply upward like a home gesture.
    @State private var touchIgnored = false
    /// True once the stroke proved horizontal intent and owns the scrubber.
    @State private var touchEngaged = false
    @State private var lastTickHapticAt = Date.distantPast
    // Reused and prepared on touch-down so each tick fires without delay.
    @State private var tickHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var markHaptic = UIImpactFeedbackGenerator(style: .medium)

    private let trackInset: CGFloat = 18
    private let tickSpacing: CGFloat = 6
    private let trackHeight: CGFloat = 44
    /// Bottom strip of the track where touches are treated as the start of a
    /// home gesture and never scrub.
    private let bottomDeadZone: CGFloat = 12
    /// Horizontal travel that proves a scrub before the track takes over.
    private let engagementSlop: CGFloat = 4
    private let buttonSize: CGFloat = 44
    private let markHapticIntensity: CGFloat = 0.8
    // Slightly below a selection tick; `.soft` at 0.15 was imperceptible.
    private let tickHapticIntensity: CGFloat = 0.5
    private let tickHapticInterval: TimeInterval = 0.03
    // Finger distance (track points) that catches / releases a section tick.
    private let detentEnterRadius: CGFloat = 9
    private let detentExitRadius: CGFloat = 15
    // Bottom-aligned tick heights on a shared baseline.
    private let tickHeight: CGFloat = 20
    private let markHeight: CGFloat = 20
    private let indicatorHeight: CGFloat = 20
    private let indicatorScrubbingHeight: CGFloat = 24

    private var canGoPrev: Bool { prevDate != nil && !navLoading }
    private var canGoNext: Bool { nextDate != nil && !navLoading }
    private var trackUsable: Bool { enabled && state.metrics.isScrollable }

    var body: some View {
        // No GlassEffectContainer: merged glass let the track's touch-down
        // drag swallow taps meant for the adjacent buttons.
        HStack(spacing: 10) {
            dayButton(icon: "chevron.left",
                      label: prevAccessibilityLabel,
                      active: canGoPrev,
                      action: onPrevDay)
            scrubberTrack
                .frame(maxWidth: .infinity)
            dayButton(icon: "chevron.right",
                      label: nextAccessibilityLabel,
                      active: canGoNext,
                      action: onNextDay)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Extra clearance above the home indicator, so swiping up to leave
        // the app is less likely to land on the scrubber track.
        .padding(.bottom, bottomSafeAreaInset() + 12)
    }

    // MARK: Day buttons

    private func dayButton(icon: String,
                          label: String,
                          active: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if navLoading {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: buttonSize, height: buttonSize)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink.opacity(active ? 1 : 0.3))
                        .frame(width: buttonSize, height: buttonSize)
                }
            }
            .contentShape(Circle())
            .glassEffect(active ? .regular.interactive() : .regular, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .accessibilityLabel(label)
    }

    // MARK: Scrubber track

    private var scrubberTrack: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    drawTicks(&context, in: size)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(width: geo.size.width))
            }
        }
        .frame(height: trackHeight)
        .glassEffect(.regular, in: .capsule)
        .opacity(trackUsable ? 1 : 0.35)
        .disabled(!trackUsable)
        .accessibilityElement()
        .accessibilityLabel(Text("快速滚动"))
        .accessibilityValue(Text("\(Int((state.metrics.progress * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            adjust(by: direction)
        }
        .accessibilityHidden(!trackUsable)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard trackUsable else { return }
                if !touchEngaged {
                    guard !touchIgnored else { return }
                    // Touches starting on the lowest strip are usually the
                    // beginning of a home gesture; never scrub from them.
                    if value.startLocation.y > trackHeight - bottomDeadZone {
                        touchIgnored = true
                        return
                    }
                    // Wait for clear horizontal intent. A steep climb belongs
                    // to the home gesture or the page flip, not the scrubber.
                    let translation = value.translation
                    guard abs(translation.width) >= engagementSlop,
                          abs(translation.width) > abs(translation.height)
                    else {
                        if translation.height < -8,
                           abs(translation.height) > abs(translation.width) * 1.2 {
                            touchIgnored = true
                        }
                        return
                    }
                    touchEngaged = true
                    state.isScrubbing = true
                    lastFingerProgress = nil
                    lastScrubTarget = nil
                    detent = nil
                    tickHaptic.prepare()
                    markHaptic.prepare()
                }
                let firstTouch = lastFingerProgress == nil
                let count = tickCount(for: width)
                let usable = usableWidth(width)
                let marks = sectionMarks(tickCount: count)
                let x = value.location.x
                let finger = DayScrubberPolicy.progress(forLocationX: x,
                                                        width: width,
                                                        inset: trackInset)
                let previousDetent = detent
                let newDetent = DayScrubberPolicy.detentIndex(
                    locationX: x,
                    markXs: marks.map { tickX($0.tick, count: count, usable: usable) },
                    current: previousDetent,
                    enterRadius: detentEnterRadius,
                    exitRadius: detentExitRadius
                )
                detent = newDetent
                fireHaptics(from: lastFingerProgress, to: finger, tickCount: count,
                            marks: marks, previousDetent: previousDetent, newDetent: newDetent)
                lastFingerProgress = finger

                // A caught section holds the page on that section's start.
                let target = newDetent.map { marks[$0].fraction } ?? finger
                guard target != lastScrubTarget else { return }
                // The first touch behaves like a tap jump (animated);
                // continued movement then tracks the finger directly.
                onScrub(target, firstTouch)
                lastScrubTarget = target
            }
            .onEnded { value in
                defer { touchIgnored = false; touchEngaged = false }
                if state.isScrubbing {
                    state.isScrubbing = false
                    lastFingerProgress = nil
                    lastScrubTarget = nil
                    detent = nil
                    return
                }
                // A stroke that never moved horizontally was a tap: jump on
                // release. Taps on the bottom dead strip do nothing.
                guard trackUsable, !touchIgnored else { return }
                let translation = value.translation
                guard abs(translation.width) < 6, abs(translation.height) < 6 else { return }
                let finger = DayScrubberPolicy.progress(forLocationX: value.location.x,
                                                        width: width,
                                                        inset: trackInset)
                onScrub(finger, true)
            }
    }

    private func adjust(by direction: AccessibilityAdjustmentDirection) {
        let step: CGFloat = 0.1
        switch direction {
        case .increment:
            onScrub(min(state.metrics.progress + step, 1), true)
        case .decrement:
            onScrub(max(state.metrics.progress - step, 0), true)
        @unknown default:
            break
        }
    }

    private func fireHaptics(from oldFinger: CGFloat?,
                             to newFinger: CGFloat,
                             tickCount: Int,
                             marks: [DayScrubberMark],
                             previousDetent: Int?,
                             newDetent: Int?) {
        if let newDetent, newDetent != previousDetent {
            markHaptic.impactOccurred(intensity: markHapticIntensity)
            markHaptic.prepare()
            return
        }
        // Held by a detent the indicator is not moving, so stay silent.
        guard newDetent == nil, let oldFinger else { return }
        // Pulling free of a caught mark already gave its bump on entry.
        let markFractions = previousDetent == nil
            ? marks.map { CGFloat($0.tick) / CGFloat(tickCount - 1) }
            : []
        let crossings = DayScrubberPolicy.crossings(from: oldFinger, to: newFinger,
                                                    tickCount: tickCount,
                                                    marks: markFractions)
        if crossings.crossesSectionMark {
            markHaptic.impactOccurred(intensity: markHapticIntensity)
            markHaptic.prepare()
        } else if crossings.tickCrossings > 0, tickHapticsEnabled {
            // Throttle so fast flicks give a texture, not a continuous buzz.
            let now = Date()
            guard now.timeIntervalSince(lastTickHapticAt) > tickHapticInterval else { return }
            lastTickHapticAt = now
            tickHaptic.impactOccurred(intensity: tickHapticIntensity)
            tickHaptic.prepare()
        }
    }

    // MARK: Tick geometry

    private func usableWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - trackInset * 2)
    }

    private func tickCount(for width: CGFloat) -> Int {
        max(2, Int(usableWidth(width) / tickSpacing) + 1)
    }

    private func tickX(_ index: Int, count: Int, usable: CGFloat) -> CGFloat {
        trackInset + CGFloat(index) / CGFloat(count - 1) * usable
    }

    private func sectionMarks(tickCount: Int) -> [DayScrubberMark] {
        guard showsSectionMarks else { return [] }
        return DayScrubberPolicy.snappedMarks(fractions: state.markFractions, tickCount: tickCount)
    }

    /// The indicator sits exactly on a section tick while caught by it, or
    /// while the page rests at that section's start; elsewhere it follows
    /// the continuous scroll progress.
    private func indicatorX(progress: CGFloat, count: Int, usable: CGFloat,
                            marks: [DayScrubberMark]) -> CGFloat {
        if state.isScrubbing, let detent, marks.indices.contains(detent) {
            return tickX(marks[detent].tick, count: count, usable: usable)
        }
        if let mark = marks.first(where: { abs($0.fraction - progress) * usable < 1.5 }) {
            return tickX(mark.tick, count: count, usable: usable)
        }
        return trackInset + progress * usable
    }

    // MARK: Tick drawing

    private func drawTicks(_ context: inout GraphicsContext, in size: CGSize) {
        let usable = usableWidth(size.width)
        guard usable > 0 else { return }
        let count = tickCount(for: size.width)
        let marks = sectionMarks(tickCount: count)
        let markTicks = Set(marks.map(\.tick))
        let currentX = indicatorX(progress: state.metrics.progress, count: count,
                                  usable: usable, marks: marks)
        // Fine ticks are centred in the track; taller ticks share their
        // bottom and grow upward.
        let baseline = (size.height + tickHeight) / 2

        // One evenly spaced row; section starts are the same ticks drawn
        // taller. Ends stay unmarked and the passed side reads darker.
        for index in 1..<(count - 1) {
            let x = tickX(index, count: count, usable: usable)
            let isMark = markTicks.contains(index)
            let passed = x <= currentX
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: baseline - (isMark ? markHeight : tickHeight)))
            tick.addLine(to: CGPoint(x: x, y: baseline))
            let opacity: Double = isMark ? (passed ? 0.8 : 0.5) : (passed ? 0.5 : 0.22)
            context.stroke(tick, with: .color(Theme.ink.opacity(opacity)), lineWidth: 1)
        }

        // Position indicator; grows slightly while scrubbing.
        let height = state.isScrubbing ? indicatorScrubbingHeight : indicatorHeight
        let rect = CGRect(x: currentX - 1, y: baseline - height, width: 2, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.ink))
    }

    // MARK: Accessibility labels

    private var prevAccessibilityLabel: String {
        if let prevDate { return "上一次，\(Self.navDateText(prevDate))" }
        return "无上一次"
    }

    private var nextAccessibilityLabel: String {
        if let nextDate { return "下一次，\(Self.navDateText(nextDate))" }
        return "无下一次"
    }

    private static func navDateText(_ date: Date) -> String {
        let components = DateText.components(date)
        return "\(components.year).\(components.month).\(components.day)"
    }
}
