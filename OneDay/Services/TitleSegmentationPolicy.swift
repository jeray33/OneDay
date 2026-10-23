import Foundation

/// Place grouping takes priority; the two time switches control separate paths.
nonisolated struct TitleSegmentationPolicy {
    enum Form: String, CaseIterable, Identifiable {
        case title, card

        var id: Self { self }
        var label: String { self == .title ? "标题" : "卡片" }
    }

    static let placeKey = "OneDay.titlePlaceSegmentation"
    static let nestedTimeKey = "OneDay.titleNestedTimeSegmentation"
    static let timeKey = "OneDay.titleTimeSegmentation"
    static let formKey = "OneDay.placeSegmentationForm"

    var placeEnabled: Bool
    var nestedTimeEnabled: Bool
    var timeEnabled: Bool
    var form: Form
    var showsNestedTimeOption: Bool { placeEnabled && form == .title }

    init(defaults: UserDefaults = .standard) {
        placeEnabled = defaults.object(forKey: Self.placeKey) as? Bool ?? true
        nestedTimeEnabled = defaults.object(forKey: Self.nestedTimeKey) as? Bool ?? false
        timeEnabled = defaults.object(forKey: Self.timeKey) as? Bool ?? true
        form = defaults.string(forKey: Self.formKey).flatMap(Form.init(rawValue:)) ?? .title
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(placeEnabled, forKey: Self.placeKey)
        defaults.set(nestedTimeEnabled, forKey: Self.nestedTimeKey)
        defaults.set(timeEnabled, forKey: Self.timeKey)
        defaults.set(form.rawValue, forKey: Self.formKey)
    }

    struct Group<Item> {
        let items: [Item]
        /// The route stop the group belongs to (nil in pure time mode), so
        /// headings can update in place after place names resolve.
        let placeID: String?
        let placeName: String?
        let showsPlaceHeading: Bool
        let timeBand: Int?
        var showsPlaceCard = false
    }

    /// Inputs are chronological. Only time grouping changes boundaries, not
    /// item order within each group. A return visit remains a separate place.
    /// `places` carries each stop's id; an unresolved stop passes
    /// `name == nil` and the heading layer reserves its space instead of
    /// inventing a placeholder name here.
    func groups<Item>(
        items: [Item],
        places: [(id: String, name: String?, items: [Item])],
        timeBand: (Item) -> Int
    ) -> [Group<Item>] {
        let nonemptyPlaces = places.filter { !$0.items.isEmpty }
        if placeEnabled, nonemptyPlaces.count >= 2 {
            return nonemptyPlaces.flatMap { place -> [Group<Item>] in
                let name = place.name.flatMap { $0.isEmpty ? nil : $0 }
                if form == .card {
                    return [Group(items: place.items, placeID: place.id, placeName: name,
                                  showsPlaceHeading: false, timeBand: nil, showsPlaceCard: true)]
                }
                if nestedTimeEnabled {
                    return splitByTime(place.items, timeBand: timeBand).enumerated().map { offset, group in
                        Group(items: group.items, placeID: place.id, placeName: name,
                              showsPlaceHeading: offset == 0, timeBand: group.band)
                    }
                }
                return [Group(items: place.items, placeID: place.id, placeName: name,
                              showsPlaceHeading: true, timeBand: nil)]
            }
        }
        if timeEnabled {
            return splitByTime(items, timeBand: timeBand).map {
                Group(items: $0.items, placeID: nil, placeName: nil,
                      showsPlaceHeading: false, timeBand: $0.band)
            }
        }
        return items.isEmpty ? [] : [
            Group(items: items, placeID: nil, placeName: nil, showsPlaceHeading: false, timeBand: nil)
        ]
    }

    private func splitByTime<Item>(
        _ items: [Item], timeBand: (Item) -> Int
    ) -> [(band: Int, items: [Item])] {
        let grouped = Dictionary(grouping: items, by: timeBand)
        return grouped.keys.sorted().map { ($0, grouped[$0]!) }
    }
}
