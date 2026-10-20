import Foundation

/// Place grouping takes priority; the two time switches control separate paths.
nonisolated struct TitleSegmentationPolicy {
    static let placeKey = "OneDay.titlePlaceSegmentation"
    static let nestedTimeKey = "OneDay.titleNestedTimeSegmentation"
    static let timeKey = "OneDay.titleTimeSegmentation"

    var placeEnabled: Bool
    var nestedTimeEnabled: Bool
    var timeEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        placeEnabled = defaults.object(forKey: Self.placeKey) as? Bool ?? true
        nestedTimeEnabled = defaults.object(forKey: Self.nestedTimeKey) as? Bool ?? false
        timeEnabled = defaults.object(forKey: Self.timeKey) as? Bool ?? true
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(placeEnabled, forKey: Self.placeKey)
        defaults.set(nestedTimeEnabled, forKey: Self.nestedTimeKey)
        defaults.set(timeEnabled, forKey: Self.timeKey)
    }

    struct Group<Item> {
        let items: [Item]
        let placeName: String?
        let showsPlaceHeading: Bool
        let timeBand: Int?
    }

    /// Inputs are chronological. Only time grouping changes boundaries, not
    /// item order within each group. A return visit remains a separate place.
    func groups<Item>(
        items: [Item],
        places: [(name: String?, items: [Item])],
        timeBand: (Item) -> Int
    ) -> [Group<Item>] {
        let nonemptyPlaces = places.filter { !$0.items.isEmpty }
        if placeEnabled, nonemptyPlaces.count >= 2 {
            return nonemptyPlaces.enumerated().flatMap { index, place -> [Group<Item>] in
                let name = place.name.flatMap { $0.isEmpty ? nil : $0 } ?? "地点 \(index + 1)"
                if nestedTimeEnabled {
                    return splitByTime(place.items, timeBand: timeBand).enumerated().map { offset, group in
                        Group(items: group.items, placeName: name,
                              showsPlaceHeading: offset == 0, timeBand: group.band)
                    }
                }
                return [Group(items: place.items, placeName: name,
                              showsPlaceHeading: true, timeBand: nil)]
            }
        }
        if timeEnabled {
            return splitByTime(items, timeBand: timeBand).map {
                Group(items: $0.items, placeName: nil,
                      showsPlaceHeading: false, timeBand: $0.band)
            }
        }
        return items.isEmpty ? [] : [
            Group(items: items, placeName: nil, showsPlaceHeading: false, timeBand: nil)
        ]
    }

    private func splitByTime<Item>(
        _ items: [Item], timeBand: (Item) -> Int
    ) -> [(band: Int, items: [Item])] {
        let grouped = Dictionary(grouping: items, by: timeBand)
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
}
