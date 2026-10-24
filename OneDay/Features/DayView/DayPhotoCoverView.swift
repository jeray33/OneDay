import Observation
import SwiftUI
import UIKit

/// Scroll state the photo cover reads every frame. A reference type so the
/// per-frame updates only invalidate the small cover views, never the day
/// grid.
@MainActor
@Observable
final class PhotoCoverScrollState {
    /// How far the day page is pulled down past its top rest, in points.
    var pull: CGFloat = 0
    /// Card travel over the photo, clamped to `0...travel`. Stops changing
    /// once the card reaches the top, so deep scrolling invalidates nothing.
    var phase: CGFloat = 0
    /// Raw scrolled distance below the top rest, for gesture handling only.
    @ObservationIgnored var scrolled: CGFloat = 0
    /// Last non-trivial per-frame scroll change; its sign is the direction.
    @ObservationIgnored var lastDelta: CGFloat = 0
    /// The SwiftUI scroll view's backing UIKit view, when it can be found.
    @ObservationIgnored weak var scrollView: UIScrollView?
    /// Drives snaps on the UIKit scroll view.
    @ObservationIgnored let spring = PhotoCardSpring()
}

/// A release that starts over the photo, or would end over it, lands only
/// below the photo or at the top: the direction of the throw decides, and
/// position decides a release without one.
///
/// The landing point is moved to the snap target, then `PhotoCardSpring`
/// takes over from the system deceleration with the finger's velocity.
/// SwiftUI exposes no way to do that, so without the UIKit scroll view this
/// only moves the landing point and the day page's spring fallback snaps.
struct PhotoCardSnapBehavior: ScrollTargetBehavior {
    static let positionThreshold: CGFloat = 0.35

    var travel: CGFloat
    var scroll: PhotoCoverScrollState

    static func restingTarget(forPosition position: CGFloat, travel: CGFloat) -> CGFloat {
        position >= travel * positionThreshold ? travel : 0
    }

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard travel > 0 else { return }
        let landing = target.rect.minY
        let current = scroll.scrolled
        let startsOverPhoto = current > 0 && current < travel
        let landsOverPhoto = landing > 0 && landing < travel
        guard startsOverPhoto || landsOverPhoto else { return }
        // A throw out of the grid that clears the photo is ordinary scrolling.
        if !startsOverPhoto && landing >= travel { return }
        let snapTarget: CGFloat
        if landing > current + 1 {
            snapTarget = travel
        } else if landing < current - 1 {
            snapTarget = 0
        } else {
            snapTarget = Self.restingTarget(forPosition: current, travel: travel)
        }
        target.rect.origin.y = snapTarget
        // Only finger releases snap; programmatic scrolls land where asked.
        guard let scrollView = scroll.scrollView, scrollView.isDragging else { return }
        let velocity = -scrollView.panGestureRecognizer.velocity(in: scrollView).y
        scroll.spring.prepare()
        DispatchQueue.main.async {
            scroll.spring.start(on: scrollView, to: snapTarget, velocity: velocity)
        }
    }
}

/// A damped spring run frame by frame on the UIKit scroll view, so a snap
/// starts at the finger's velocity and stops the moment the page is touched
/// again. Returning to the photo overshoots into a small zoom bounce; rising
/// to the top is slightly underdamped so the throw keeps its punch, while the
/// clamp below still prevents a visual overshoot that would wobble the
/// content under the top bar's title and blur. Both rests tap with the same
/// full-strength haptic as a flip to the back cover.
@MainActor
final class PhotoCardSpring: NSObject {
    /// ≈0.41 s response; the damping leaves about 40 pt of overshoot.
    static let stiffness: CGFloat = 235
    static let dampingRatio: CGFloat = 0.57
    /// Slightly underdamped rise: faster, forceful arrival, no overshoot.
    static let risingDampingRatio: CGFloat = 0.85
    private static let maxVelocity: CGFloat = 4000
    /// Same full-strength tap as a page flip.
    static let hapticIntensity: CGFloat = 1

    private var link: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var target: CGFloat = 0
    private var position: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private var touchReleased = false
    private var pending = false
    private var arrived = false
    private var startSide: CGFloat = 0
    private var rising = false
    private let haptic = UIImpactFeedbackGenerator(style: .soft)

    /// True from the release that will snap until the spring settles or
    /// is interrupted.
    var isActive: Bool { pending || link != nil }

    /// Marks a snap as coming, before `start` runs on the next turn.
    func prepare() { pending = true }

    /// Positions are scroll distances below the top rest, insets excluded.
    func start(on scrollView: UIScrollView, to target: CGFloat, velocity: CGFloat) {
        stop()
        guard scrollView.window != nil else { return }
        self.scrollView = scrollView
        self.target = target
        self.velocity = min(max(velocity, -Self.maxVelocity), Self.maxVelocity)
        position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        touchReleased = !scrollView.isTracking
        startSide = position - target
        rising = target > position
        arrived = abs(startSide) < 1
        if !arrived { haptic.prepare() }
        // Setting the current offset halts the system deceleration.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        lastTime = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        pending = false
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView, scrollView.window != nil else { stop(); return }
        // A new touch takes the page; the release that started the spring
        // may still read as tracking for a moment.
        if scrollView.isTracking {
            if touchReleased { stop(); return }
        } else {
            touchReleased = true
        }
        let state = scrollView.panGestureRecognizer.state
        if state == .began || state == .changed { stop(); return }

        let now = link.targetTimestamp
        var remaining = min(max(now - lastTime, 0), 1.0 / 30)
        lastTime = now
        let ratio = rising ? Self.risingDampingRatio : Self.dampingRatio
        let damping = 2 * ratio * Self.stiffness.squareRoot()
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            let acceleration = -Self.stiffness * (position - target) - damping * velocity
            velocity += acceleration * h
            position += velocity * h
            remaining -= h
            // A fast throw can still carry a critically damped spring past.
            if rising, position >= target {
                position = target
                velocity = 0
                break
            }
        }
        if !arrived, (position - target) * startSide <= 0 {
            arrived = true
            haptic.impactOccurred(intensity: Self.hapticIntensity)
        }
        let settled = abs(position - target) < 0.3 && abs(velocity) < 6
        if settled { position = target }
        scrollView.contentOffset.y = position - scrollView.adjustedContentInset.top
        if settled { stop() }
    }
}

/// Finds the UIKit scroll view hosting this view.
struct EnclosingScrollViewReader: UIViewRepresentable {
    var onFind: (UIScrollView) -> Void

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.onFind = onFind
        return view
    }

    func updateUIView(_ view: FinderView, context: Context) {
        view.onFind = onFind
    }

    final class FinderView: UIView {
        var onFind: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                var view = self?.superview
                while let candidate = view {
                    if let scrollView = candidate as? UIScrollView {
                        self?.onFind?(scrollView)
                        return
                    }
                    view = candidate.superview
                }
            }
        }
    }
}

/// Opaque page color tracking the card's top edge, behind the scroll view.
/// The bars' soft scroll-edge effect fades the card itself out, and without
/// this the fixed photo (top) or the back page (bottom) would show through.
struct PhotoCardBackdrop: View {
    var scroll: PhotoCoverScrollState
    var coverHeight: CGFloat
    /// Scroll distance at which the card reaches the top bar.
    var travel: CGFloat
    var color: Color

    var body: some View {
        let radius = DayPhotoCoverView.cardRadius(phase: scroll.phase, travel: travel)
        let top = DayPhotoCoverView.cardTop(phase: scroll.phase, coverHeight: coverHeight,
                                            travel: travel) + scroll.pull
        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius,
                               style: .continuous)
            .fill(color)
            .padding(.top, top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

/// The day page card's own background, inside the scroll content. A
/// separate view so the corner animation never re-evaluates the grid.
struct PhotoCardBackground: View {
    var scroll: PhotoCoverScrollState
    var coverHeight: CGFloat
    var travel: CGFloat
    var color: Color

    var body: some View {
        let radius = DayPhotoCoverView.cardRadius(phase: scroll.phase, travel: travel)
        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius,
                               style: .continuous)
            .fill(color)
            .padding(.top, DayPhotoCoverView.cardTopInContent(
                phase: scroll.phase, coverHeight: coverHeight, travel: travel))
    }
}

/// Clips content that starts flush with the card to the card's top edge
/// and corners. The card's edge runs ahead of the content, so content that
/// draws above its own frame (the map's top extension) follows the edge up.
struct PhotoCardTopClip: ViewModifier {
    var scroll: PhotoCoverScrollState?
    var coverHeight: CGFloat
    var travel: CGFloat

    func body(content: Content) -> some View {
        if let scroll {
            let phase = scroll.phase
            let lead = travel - DayPhotoCoverView.cardTopInContent(
                phase: phase, coverHeight: coverHeight, travel: travel)
            content.clipShape(CardTopShape(
                lead: lead, radius: DayPhotoCoverView.cardRadius(phase: phase, travel: travel)))
        } else {
            content
        }
    }

    private struct CardTopShape: Shape {
        var lead: CGFloat
        var radius: CGFloat

        func path(in rect: CGRect) -> Path {
            var extended = rect
            extended.origin.y -= lead
            extended.size.height += lead
            return UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius,
                                          style: .continuous).path(in: extended)
        }
    }
}

/// Fixed full-bleed photo behind the day page, with the relative caption
/// and big date centered in its visible part.
struct DayPhotoCoverView: View {
    static let cardCornerRadius: CGFloat = 24
    /// The photo follows the card upward at this fraction of its speed.
    private static let parallax: CGFloat = 0.25
    private static let maxCoverDim: Double = 0.30
    /// Card travel over which the corners flatten before reaching the top.
    private static let cornerFlattenDistance: CGFloat = 30

    var model: DayViewModel
    var scroll: PhotoCoverScrollState
    var width: CGFloat
    /// Height left uncovered by the day page at rest.
    var visibleHeight: CGFloat
    /// Scroll distance at which the card reaches the top bar.
    var travel: CGFloat
    var dateNamespace: Namespace.ID? = nil
    var dateIsSource: Bool = false

    /// 1 until the card's last stretch below the top bar, then down to 0.
    static func cornerFactor(phase: CGFloat, travel: CGFloat) -> CGFloat {
        min(max((travel - phase) / cornerFlattenDistance, 0), 1)
    }

    /// Screen y of the card's top edge. The edge runs slightly ahead of the
    /// content so it reaches the screen top exactly as the content reaches
    /// the header, instead of only passing under the header.
    static func cardTop(phase: CGFloat, coverHeight: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return coverHeight }
        return coverHeight * (1 - min(max(phase / travel, 0), 1))
    }

    /// `cardTop` in scroll content coordinates, where the content starts
    /// below the header (`coverHeight - travel` tall).
    static func cardTopInContent(phase: CGFloat, coverHeight: CGFloat, travel: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        return travel - (coverHeight - travel) * min(max(phase / travel, 0), 1)
    }

    static func cardRadius(phase: CGFloat, travel: CGFloat) -> CGFloat {
        cardCornerRadius * cornerFactor(phase: phase, travel: travel)
    }

    /// The photo runs under the card's rounded top corners so no gap shows.
    private var photoHeight: CGFloat { visibleHeight + Self.cardCornerRadius }

    var body: some View {
        let phase = scroll.phase
        let progress = travel > 0 ? phase / travel : 0
        // Anchored at the top, the scaled bottom edge tracks the card as it
        // is pulled down.
        let scale = 1 + scroll.pull / max(visibleHeight, 1)
        PhotoCoverContent(model: model, width: width, photoHeight: photoHeight,
                          visibleHeight: visibleHeight,
                          textProgress: textFadeProgress(phase),
                          dateNamespace: dateNamespace, dateIsSource: dateIsSource)
            .overlay(Color.black.opacity(Self.maxCoverDim * Double(progress)))
            .scaleEffect(scale, anchor: .top)
            .offset(y: -phase * Self.parallax)
            .frame(width: width, height: photoHeight, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    /// 0…1, reaching 1 a little before the rising card would meet the
    /// text's lower edge (which itself drifts up with the parallax).
    private func textFadeProgress(_ phase: CGFloat) -> CGFloat {
        let textBottomGap = visibleHeight / 2 - 44
        let cardSpeed = travel > 0 ? visibleHeight / travel : 1
        let meet = textBottomGap / max(cardSpeed - Self.parallax, 0.1)
        let fadeDistance = max(meet * 0.8, 1)
        return min(max(phase / fadeDistance, 0), 1)
    }
}

private struct PhotoCoverContent: View {
    var model: DayViewModel
    var width: CGFloat
    var photoHeight: CGFloat
    var visibleHeight: CGFloat
    var textProgress: CGFloat
    var dateNamespace: Namespace.ID?
    var dateIsSource: Bool

    var body: some View {
        let titleSize = min(width * 0.145, 58)
        ZStack(alignment: .top) {
            Color(white: 0.22)
            if let item = model.photoCoverItem {
                PHImageView(asset: item.asset,
                            displaySize: CGSize(width: width, height: photoHeight),
                            highQuality: true,
                            progressive: true)
                    .id(item.id)
                    .transition(.opacity)
            }
            scrim

            VStack(spacing: 6) {
                Text(CoverRelativeCaption.text(for: model.date))
                    .font(Theme.serif(17, weight: .medium))
                Text(DateText.dottedDate(model.date))
                    .font(model.coverDateFont.font(titleSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .modifier(OptionalMatchedDate(namespace: dateNamespace, isSource: dateIsSource))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
            .frame(width: width - 40)
            .scaleEffect(1 - 0.04 * textProgress)
            .opacity(1 - Double(textProgress))
            .position(x: width / 2, y: visibleHeight / 2 - 24 * textProgress)
            .accessibilityElement(children: .combine)
        }
        .frame(width: width, height: photoHeight)
        .clipped()
        .animation(.easeInOut(duration: 0.35), value: model.photoCoverItem?.id)
    }

    /// A light overall dim plus a soft center pool keeps white text legible
    /// on bright photos without visibly darkening ordinary ones.
    private var scrim: some View {
        ZStack {
            Color.black.opacity(0.10)
            RadialGradient(
                colors: [.black.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: visibleHeight / 2 / max(photoHeight, 1)),
                startRadius: 0,
                endRadius: width * 0.75
            )
        }
    }
}

/// Shares the timeline date transition without requiring a separate cover page.
private struct OptionalMatchedDate: ViewModifier {
    var namespace: Namespace.ID?
    var isSource: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "flowDate", in: namespace, isSource: isSource)
        } else {
            content
        }
    }
}
