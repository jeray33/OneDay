import Foundation
import CoreGraphics

nonisolated enum DayContentCoordinates {
    static func screenRect(for rect: CGRect, scrollOffset: CGFloat, topInset: CGFloat) -> CGRect {
        rect.offsetBy(dx: 0, dy: topInset - scrollOffset)
    }

    static func contentRect(for rect: CGRect, scrollOffset: CGFloat, topInset: CGFloat) -> CGRect {
        rect.offsetBy(dx: 0, dy: scrollOffset - topInset)
    }

    static func targetOffset(
        for rect: CGRect, viewport: CGRect, currentOffset: CGFloat, anchor: CGFloat
    ) -> CGFloat? {
        guard !rect.isEmpty, !viewport.isEmpty else { return nil }
        let fraction = min(max(anchor, 0), 1)
        let target = currentOffset + rect.minY + rect.height * fraction
            - viewport.minY - viewport.height * fraction
        return target.isFinite ? max(0, target) : nil
    }
}

nonisolated struct DayGridLayoutRevision: Equatable {
    let instanceID: UUID
    let category: String?
    let arrangement: DayGridArrangement
    let columns: Int
    let width: CGFloat
    let sideSpacing: DayPhotoSideSpacing
    let horizontalSpacing: CGFloat?
    let verticalSpacing: CGFloat
    let border: String
    let showsCaptions: Bool
    let captions: [String?]
    let itemIDs: [String]
    let sections: [UUID]
    var placeCardIDs: [String] = []
    var cardPhotoFallbacks: [String: String] = [:]
    var segmentationForm: String = "title"
    var placeCardFlow: PlaceCardFlow = .separated
    var contentRevision: UUID? = nil
    var titleSize: CGFloat = 0
    var titleFont: String = ""
    var placeCardRatio: String = ""
    var placesRevision: UUID? = nil
}

/// Results are staged while any interaction owns the page's position.
nonisolated struct DayPlaceInteractionState {
    enum Activity { case scrolling, pinching, scrubbing, transitioning }
    private var scrolling = false
    private var pinching = false
    private var scrubbing = false
    private var transitioning = false

    var isIdle: Bool { !scrolling && !pinching && !scrubbing && !transitioning }

    mutating func set(_ activity: Activity, active: Bool) {
        switch activity {
        case .scrolling: scrolling = active
        case .pinching: pinching = active
        case .scrubbing: scrubbing = active
        case .transitioning: transitioning = active
        }
    }
}

/// A non-observable reference, so per-scroll measurements don't invalidate the
/// grid. Reflows retain a visible photo, not a percentage of the old height.
nonisolated final class DayGridAnchorTracker {
    enum Adjustment: Equatable {
        case offset(CGFloat)
        case reveal(String)
    }

    private var revision: DayGridLayoutRevision?
    private var frames: [String: CGRect] = [:]
    private var pendingAnchor: WaterfallLayoutPolicy.Anchor?
    private var requestedReveal = false
    private var explicitPlaceAnchor = false
    private var capturedOffset: CGFloat?
    private var capturedRevision: DayGridLayoutRevision?

    /// Capture before SwiftUI can clamp/adjust its offset for the new content.
    func capturePlaceAnchor(viewport: CGRect, offset: CGFloat) {
        guard let revision else { return }
        let photos = Set(revision.itemIDs)
        pendingAnchor = WaterfallLayoutPolicy.anchor(
            frames: frames.filter { photos.contains($0.key) }, viewport: viewport)
            ?? WaterfallLayoutPolicy.anchor(frames: frames, viewport: viewport)
        explicitPlaceAnchor = pendingAnchor != nil
        capturedOffset = explicitPlaceAnchor ? offset : nil
        capturedRevision = explicitPlaceAnchor ? revision : nil
        requestedReveal = false
    }

    func update(
        frames newFrames: [String: CGRect], revision newRevision: DayGridLayoutRevision,
        viewport: CGRect, offset: CGFloat, enabled: Bool
    ) -> Adjustment? {
        defer {
            frames = newFrames
            revision = newRevision
        }
        // Category/day changes intentionally keep their existing top reset.
        guard enabled, let revision,
              revision.instanceID == newRevision.instanceID,
              revision.category == newRevision.category else {
            pendingAnchor = nil
            requestedReveal = false
            explicitPlaceAnchor = false
            capturedOffset = nil
            capturedRevision = nil
            return nil
        }
        if explicitPlaceAnchor, capturedRevision == newRevision { return nil }
        if revision != newRevision, !explicitPlaceAnchor {
            pendingAnchor = nil
            requestedReveal = false
            capturedOffset = nil
            capturedRevision = nil
            if revision.arrangement == .waterfall || newRevision.arrangement == .waterfall
                || revision.sideSpacing != newRevision.sideSpacing
                || revision.segmentationForm != newRevision.segmentationForm
                || revision.sections != newRevision.sections
                || revision.placesRevision != newRevision.placesRevision
                || !revision.placeCardIDs.isEmpty || !newRevision.placeCardIDs.isEmpty {
                // A removed card cannot serve as a return anchor.
                let survivingIDs = Set(newRevision.itemIDs + newRevision.placeCardIDs)
                pendingAnchor = WaterfallLayoutPolicy.anchor(
                    frames: frames.filter { survivingIDs.contains($0.key) },
                    viewport: viewport
                )
                // A single-column place card can fill the entire viewport.
                // Removing it should reveal its first photo, not lose the
                // section's position simply because no photo was visible.
                if pendingAnchor == nil {
                    let oldCardIDs = Set(revision.placeCardIDs)
                    if let oldCard = WaterfallLayoutPolicy.anchor(
                        frames: frames.filter { oldCardIDs.contains($0.key) }, viewport: viewport
                    ), let photoID = revision.cardPhotoFallbacks[oldCard.id],
                       survivingIDs.contains(photoID) {
                        pendingAnchor = WaterfallLayoutPolicy.Anchor(id: photoID, minY: oldCard.minY)
                    }
                }
            }
        }
        if explicitPlaceAnchor, let anchor = pendingAnchor,
           !Set(newRevision.itemIDs + newRevision.placeCardIDs).contains(anchor.id),
           let photo = revision.cardPhotoFallbacks[anchor.id] {
            pendingAnchor = .init(id: photo, minY: anchor.minY)
        }
        guard let anchor = pendingAnchor else { return nil }
        if let target = WaterfallLayoutPolicy.restoredOffset(
            anchor: anchor, frames: newFrames, currentOffset: capturedOffset ?? offset
        ) {
            pendingAnchor = nil
            requestedReveal = false
            explicitPlaceAnchor = false
            capturedOffset = nil
            capturedRevision = nil
            return abs(target - offset) > 1 ? .offset(target) : nil
        }
        // LazyVGrid may not yet have instantiated the waterfall anchor when
        // switching back. Reveal its stable block ID, then correct its offset.
        guard !requestedReveal else { return nil }
        requestedReveal = true
        return .reveal(anchor.id)
    }
}
