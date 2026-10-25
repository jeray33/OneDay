import Foundation

nonisolated enum DayMediaTab: String, Identifiable, Sendable {
    case photoVideo, screenshot, otherImage, featured

    init(category: MediaCategory) {
        switch category {
        case .photoVideo: self = .photoVideo
        case .screenshot: self = .screenshot
        case .otherImage: self = .otherImage
        }
    }

    var id: String { rawValue }
    var category: MediaCategory? { MediaCategory(rawValue: rawValue) }
    var tabLabel: String { category?.tabLabel ?? "精选" }
    var label: String { category?.label ?? "精选照片和视频" }
}

/// A day's body inventory, after shared-source controls but before selecting a Tab.
/// Classification is supplied by the caller so availability and fallback are testable.
nonisolated struct DayMediaTabs<Item> {
    private let itemsByCategory: [MediaCategory: [Item]]
    let availableCategories: [MediaCategory]
    let availableTabs: [DayMediaTab]
    private let featuredItems: [Item]

    init(
        items: [Item], featuredEnabled: Bool = false, featured: (Item) -> Bool = { _ in false },
        category: (Item) -> MediaCategory?
    ) {
        var groups: [MediaCategory: [Item]] = [:]
        for item in items {
            guard let category = category(item) else { continue }
            groups[category, default: []].append(item)
        }
        itemsByCategory = groups
        availableCategories = MediaCategory.allCases.filter { groups[$0]?.isEmpty == false }
        featuredItems = featuredEnabled ? (groups[.photoVideo] ?? []).filter(featured) : []
        var tabs = availableCategories.map(DayMediaTab.init(category:))
        // Keep the tab discoverable while scores are still being prepared.
        if featuredEnabled, groups[.photoVideo]?.isEmpty == false { tabs.append(.featured) }
        availableTabs = tabs
    }

    var showsTabBar: Bool { availableTabs.count > 1 }

    func tabSelection(preserving selected: DayMediaTab?) -> DayMediaTab? {
        if let selected, availableTabs.contains(selected) { return selected }
        return availableTabs.first
    }

    func items(inTab tab: DayMediaTab?) -> [Item] {
        guard let tab else { return [] }
        if tab == .featured { return featuredItems }
        return items(in: tab.category)
    }

    func selection(preserving selected: MediaCategory?) -> MediaCategory? {
        if let selected, availableCategories.contains(selected) { return selected }
        return availableCategories.first
    }

    func items(in category: MediaCategory?) -> [Item] {
        guard let category else { return [] }
        return itemsByCategory[category] ?? []
    }
}

/// Proportion of scored group representatives to keep for each media type.
nonisolated enum FeaturedMediaAmount: Int, CaseIterable, Identifiable, Sendable {
    case strict = 20
    case balanced = 40
    case generous = 60

    static let storageKey = "OneDay.featuredMediaAmount"
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .strict: return "严格（20%）"
        case .balanced: return "均衡（40%）"
        case .generous: return "宽松（60%）"
        }
    }

    static func saved(defaults: UserDefaults = .standard) -> Self {
        guard let value = defaults.object(forKey: storageKey) as? NSNumber else { return .balanced }
        return allCases.first { Double($0.rawValue) == value.doubleValue } ?? .balanced
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    func count(from total: Int) -> Int {
        guard total > 0 else { return 0 }
        // Round up so a small, scored photo/video set is not lost completely.
        return total / 100 * rawValue + (total % 100 * rawValue + 99) / 100
    }
}

/// Relative quality, not an absolute "good/bad" judgment. Missing scores are
/// unknown, and ties preserve the original order.
nonisolated enum FeaturedMediaPolicy {
    static let enabledKey = "OneDay.featuredTabEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func bestItems<Item>(in groups: [[Item]], score: (Item) -> Float?) -> [Item] {
        groups.compactMap { group in
            var best: Item?
            var bestScore = -Float.infinity
            for item in group {
                guard let value = score(item), value.isFinite, value > bestScore else { continue }
                best = item
                bestScore = value
            }
            return best
        }
    }

    static func curatedItems<Item>(
        in groups: [[Item]], amount: FeaturedMediaAmount,
        isVideo: (Item) -> Bool, score: (Item) -> Float?
    ) -> [Item] {
        let best = bestItems(in: groups, score: score)
        let candidates = best.enumerated().compactMap { index, item -> (index: Int, item: Item, video: Bool, score: Float)? in
            guard let value = score(item), value.isFinite else { return nil }
            return (index, item, isVideo(item), value)
        }
        var selected = Set<Int>()
        for video in [false, true] {
            let ranked = candidates.filter { $0.video == video }.sorted {
                $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
            }
            selected.formUnion(ranked.prefix(amount.count(from: ranked.count)).map(\.index))
        }
        // Ranking determines membership, not the chronological display order.
        return candidates.filter { selected.contains($0.index) }.map(\.item)
    }
}
