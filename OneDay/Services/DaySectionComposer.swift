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
                blocks: group.map { MagazineBlock(items: [$0]) },
                placeHeading: planned.showsPlaceHeading ? planned.placeName : nil,
                placeHeadingPending: planned.showsPlaceHeading && planned.placeName == nil,
                showsTimeHeading: planned.timeBand != nil,
                timeHeadingIsNested: planned.placeID != nil && planned.timeBand != nil,
                placeCard: card
            )
        }
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
