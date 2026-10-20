/// A day's body inventory, after shared-source controls but before selecting a Tab.
/// Classification is supplied by the caller so availability and fallback are testable.
nonisolated struct DayMediaTabs<Item> {
    private let itemsByCategory: [MediaCategory: [Item]]
    let availableCategories: [MediaCategory]

    init(items: [Item], category: (Item) -> MediaCategory?) {
        var groups: [MediaCategory: [Item]] = [:]
        for item in items {
            guard let category = category(item) else { continue }
            groups[category, default: []].append(item)
        }
        itemsByCategory = groups
        availableCategories = MediaCategory.allCases.filter { groups[$0]?.isEmpty == false }
    }

    var showsTabBar: Bool { availableCategories.count > 1 }

    func selection(preserving selected: MediaCategory?) -> MediaCategory? {
        if let selected, availableCategories.contains(selected) { return selected }
        return availableCategories.first
    }

    func items(in category: MediaCategory?) -> [Item] {
        guard let category else { return [] }
        return itemsByCategory[category] ?? []
    }
}
