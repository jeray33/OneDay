import Foundation
import CoreGraphics

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
            return nil
        }
        if revision != newRevision {
            pendingAnchor = nil
            requestedReveal = false
            if revision.arrangement == .waterfall || newRevision.arrangement == .waterfall
                || revision.sideSpacing != newRevision.sideSpacing
                || revision.segmentationForm != newRevision.segmentationForm
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
        guard let anchor = pendingAnchor else { return nil }
        if let target = WaterfallLayoutPolicy.restoredOffset(
            anchor: anchor, frames: newFrames, currentOffset: offset
        ) {
            pendingAnchor = nil
            requestedReveal = false
            return abs(target - offset) > 1 ? .offset(target) : nil
        }
        // LazyVGrid may not yet have instantiated the waterfall anchor when
        // switching back. Reveal its stable block ID, then correct its offset.
        guard !requestedReveal else { return nil }
        requestedReveal = true
        return .reveal(anchor.id)
    }
}
