import Foundation
import CoreLocation

/// Groups the chronological grid by the saved place/time heading policy.
enum DaySectionComposer {
    static func compose(
        _ items: [PhotoItem],
        policy: TitleSegmentationPolicy,
        places: [(id: String, name: String?, items: [PhotoItem])] = []
    ) -> [MagazineSection] {
        let sorted = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        let groups = policy.groups(items: sorted, places: places) {
            TimeBand.band(for: $0.creationDate, in: $0.captureTimeZone).rawValue
        }
        var previousPaletteIndex: Int?
        return groups.map { planned in
            let group = planned.items
            let timeText = timeRange(group)
            var card: PlaceSectionCard?
            if planned.showsPlaceCard, let stopID = planned.placeID, let first = group.first {
                card = PlaceSectionCard(
                    stopID: stopID, firstPhotoID: first.id, placeName: planned.placeName,
                    timeText: timeText, avoiding: previousPaletteIndex
                )
                previousPaletteIndex = card?.paletteIndex
            }
            let band = planned.timeBand.flatMap(TimeBand.init(rawValue:))
                ?? TimeBand.band(for: group.first?.creationDate,
                                 in: group.first?.captureTimeZone ?? .current)
            return MagazineSection(
                band: band,
                timeText: timeText,
                placeName: planned.placeName,
                placeStopID: planned.placeID,
                anchorLocation: group.first(where: { $0.location != nil })?.location,
                blocks: photoBlocks(group),
                placeHeading: planned.showsPlaceHeading ? planned.placeName : nil,
                placeHeadingPending: planned.showsPlaceHeading && planned.placeName == nil,
                showsTimeHeading: planned.timeBand != nil,
                timeHeadingIsNested: planned.placeID != nil && planned.timeBand != nil,
                placeCard: card
            )
        }
    }

    private static func photoBlocks(_ items: [PhotoItem]) -> [MagazineBlock] {
        let store = SimilarityFeatureStore.shared
        return similarGroups(items).map { group in
            guard group.count > 1 else { return MagazineBlock(items: group) }
            let representative = group.enumerated().max { a, b in
                if a.element.isFavorite != b.element.isFavorite { return !a.element.isFavorite }
                let lhs = store.score(a.element) ?? -.infinity
                let rhs = store.score(b.element) ?? -.infinity
                if lhs != rhs { return lhs < rhs }
                return abs(a.offset - group.count / 2) > abs(b.offset - group.count / 2)
            }?.element
            return MagazineBlock(items: group, representativeID: representative?.id,
                                 groupID: group.first?.id)
        }
    }

    /// Featured selection shares scene boundaries but works independently of
    /// whether the user currently collapses similar cards in the normal tabs.
    static func similarGroups(_ items: [PhotoItem], ignoringOffSwitch: Bool = false) -> [[PhotoItem]] {
        let folding = SimilarPhotoFoldingPreferences()
        let level = ignoringOffSwitch && !folding.isEnabled ? folding.lastEnabledLevel : folding.level
        let store = SimilarityFeatureStore.shared
        return SimilarPhotoGrouping.groups(
            items, level: level, parameters: folding.parameters, date: { $0.creationDate },
            eligible: { $0.creationDate != nil },
            distance: { store.distance($0, $1) },
            compatible: { a, b in
                a.isVideo == b.isVideo
                    && (!a.isVideo || VideoSimilarityPolicy.compatibleDurations(a.duration, b.duration))
            },
            nearby: { a, b in
                guard let a = a.location, let b = b.location,
                      a.horizontalAccuracy >= 0, b.horizontalAccuracy >= 0 else { return true }
                return a.distance(from: b) <= 50 + a.horizontalAccuracy + b.horizontalAccuracy
            }
        )
    }

    /// Each end reads in its own capture's local zone.
    private static func timeRange(_ items: [PhotoItem]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        func text(_ item: PhotoItem) -> String {
            formatter.timeZone = item.captureTimeZone
            return formatter.string(from: item.creationDate ?? .distantPast)
        }
        let dated = items.filter { $0.creationDate != nil }
            .sorted { $0.creationDate! < $1.creationDate! }
        guard let first = dated.first else { return "" }
        guard let last = dated.last, last.creationDate != first.creationDate else { return text(first) }
        return "\(text(first)) – \(text(last))"
    }
}
