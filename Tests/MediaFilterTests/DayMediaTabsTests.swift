import XCTest
@testable import MediaFilter

final class DayMediaTabsTests: XCTestCase {
    private struct Item {
        let id: String
        let category: MediaCategory?
        var shared = false
        var ownContribution = false
    }

    private func tabs(_ items: [Item]) -> DayMediaTabs<Item> {
        DayMediaTabs(items: items, category: \.category)
    }

    func testEveryAvailabilityCombinationHasOnlyNonemptyTabsInFixedOrder() {
        for mask in 0..<8 {
            let available = MediaCategory.allCases.enumerated().compactMap { index, category in
                mask & (1 << index) != 0 ? category : nil
            }
            let source = available.reversed().flatMap {
                [Item(id: "\($0)-1", category: $0), Item(id: "\($0)-2", category: $0)]
            }
            let state = tabs(source)
            XCTAssertEqual(state.availableCategories, available)
            XCTAssertEqual(state.showsTabBar, available.count > 1)
            XCTAssertEqual(state.selection(preserving: nil), available.first)
            for category in MediaCategory.allCases {
                XCTAssertEqual(state.items(in: category).count, available.contains(category) ? 2 : 0)
                XCTAssertEqual(state.selection(preserving: category),
                               available.contains(category) ? category : available.first)
            }
        }
    }

    func testTabSelectionNeverChangesSourceOrderOrIncludesOtherCategories() {
        let source = [
            Item(id: "photo-1", category: .photoVideo),
            Item(id: "screen", category: .screenshot),
            Item(id: "photo-2", category: .photoVideo),
            Item(id: "long", category: .otherImage),
            Item(id: "unsupported", category: nil)
        ]
        let state = tabs(source)
        XCTAssertEqual(state.items(in: .photoVideo).map(\.id), ["photo-1", "photo-2"])
        XCTAssertEqual(state.items(in: .screenshot).map(\.id), ["screen"])
        XCTAssertEqual(state.items(in: .otherImage).map(\.id), ["long"])
        XCTAssertTrue(state.items(in: nil).isEmpty)
    }

    func testClassificationResultsAddATabWithoutStealingTheCurrentSelection() {
        let initial = tabs([Item(id: "unknown", category: .photoVideo),
                            Item(id: "screen", category: .screenshot)])
        let active = initial.selection(preserving: .screenshot)
        let classified = tabs([Item(id: "unknown", category: .otherImage),
                               Item(id: "screen", category: .screenshot)])
        XCTAssertEqual(classified.availableCategories, [.screenshot, .otherImage])
        XCTAssertEqual(classified.selection(preserving: active), .screenshot)
        XCTAssertEqual(classified.selection(preserving: .photoVideo), .screenshot)
    }

    func testCorrectingOrDeletingTheLastItemFallsBackToFirstAvailableCategory() {
        let corrected = tabs([Item(id: "last-photo", category: .otherImage)])
        XCTAssertEqual(corrected.selection(preserving: .photoVideo), .otherImage)
        XCTAssertFalse(corrected.showsTabBar)
        let deleted = tabs([])
        XCTAssertTrue(deleted.availableCategories.isEmpty)
        XCTAssertNil(deleted.selection(preserving: .otherImage))
        XCTAssertFalse(deleted.showsTabBar)
    }

    func testOnlyTabsFromTheCurrentSharedSourceAreAvailable() {
        let source = [
            Item(id: "original", category: .photoVideo),
            Item(id: "foreign-screen", category: .screenshot, shared: true),
            Item(id: "own-shared", category: .otherImage, shared: true, ownContribution: true)
        ]
        for includeShared in [false, true] {
            let body = DayMediaScope.bodyItems(
                from: source, includeShared: includeShared,
                isShared: \.shared, isOwnSharedContribution: \.ownContribution)
            let state = tabs(body)
            XCTAssertEqual(state.availableCategories.contains(.screenshot), includeShared)
            XCTAssertFalse(state.availableCategories.contains(.otherImage))
            XCTAssertEqual(state.selection(preserving: .otherImage), .photoVideo)
        }
    }

    func testEachNewDayDefaultsToItsOwnFirstAvailableTab() {
        let previous = tabs([Item(id: "a", category: .photoVideo),
                             Item(id: "b", category: .otherImage)])
        XCTAssertEqual(previous.selection(preserving: .otherImage), .otherImage)
        let next = tabs([Item(id: "c", category: .screenshot),
                         Item(id: "d", category: .photoVideo)])
        XCTAssertEqual(next.selection(preserving: nil), .photoVideo)
        let screenshotsOnly = tabs([Item(id: "e", category: .screenshot)])
        XCTAssertEqual(screenshotsOnly.selection(preserving: nil), .screenshot)
        XCTAssertFalse(screenshotsOnly.showsTabBar)
    }

    func testFeaturedIsAnAdditionalTabWithoutChangingOriginalInventory() {
        let source = [
            Item(id: "best", category: .photoVideo),
            Item(id: "other-photo", category: .photoVideo),
            Item(id: "screen", category: .screenshot),
            Item(id: "long-image", category: .otherImage)
        ]
        let state = DayMediaTabs(items: source, featuredEnabled: true,
                                 featured: { ["best", "screen", "long-image"].contains($0.id) },
                                 category: \.category)
        XCTAssertEqual(state.availableTabs, [.photoVideo, .screenshot, .otherImage, .featured])
        XCTAssertEqual(state.items(inTab: .featured).map(\.id), ["best"])
        XCTAssertEqual(state.items(inTab: .photoVideo).map(\.id), ["best", "other-photo"])
        XCTAssertEqual(state.items(inTab: .screenshot).map(\.id), ["screen"])
        XCTAssertEqual(state.items(inTab: .otherImage).map(\.id), ["long-image"])
        XCTAssertEqual(state.tabSelection(preserving: nil), .photoVideo)
        XCTAssertEqual(state.tabSelection(preserving: .screenshot), .screenshot)
    }

    func testFeaturedRemainsAvailableWhileScoresArePending() {
        let state = DayMediaTabs(items: [Item(id: "pending", category: .photoVideo)],
                                 featuredEnabled: true, category: \.category)
        XCTAssertEqual(state.availableTabs, [.photoVideo, .featured])
        XCTAssertTrue(state.items(inTab: .featured).isEmpty)
        XCTAssertEqual(state.tabSelection(preserving: .featured), .featured)
        XCTAssertTrue(state.showsTabBar)
    }

    func testDisablingFeaturedFallsBackWithoutRemovingAnyOriginals() {
        let source = [Item(id: "a", category: .photoVideo)]
        let state = DayMediaTabs(items: source, featuredEnabled: false,
                                 featured: { _ in true }, category: \.category)
        XCTAssertEqual(state.availableTabs, [.photoVideo])
        XCTAssertEqual(state.tabSelection(preserving: .featured), .photoVideo)
        XCTAssertEqual(state.items(inTab: .photoVideo).map(\.id), ["a"])
        XCTAssertTrue(state.items(inTab: .featured).isEmpty)
    }

    func testDaysWithoutCameraMediaDoNotShowAnEmptyFeaturedTab() {
        let state = DayMediaTabs(items: [Item(id: "screen", category: .screenshot)],
                                 featuredEnabled: true, featured: { _ in true }, category: \.category)
        XCTAssertEqual(state.availableTabs, [.screenshot])
        XCTAssertEqual(state.tabSelection(preserving: .featured), .screenshot)
        XCTAssertTrue(state.items(inTab: nil).isEmpty)
    }

    func testFeaturedCannotReintroduceItemsRemovedBySharedSourceControls() {
        let source = [
            Item(id: "own", category: .photoVideo),
            Item(id: "shared", category: .photoVideo, shared: true),
            Item(id: "own-copy", category: .photoVideo, shared: true, ownContribution: true)
        ]
        for includeShared in [false, true] {
            let body = DayMediaScope.bodyItems(
                from: source, includeShared: includeShared,
                isShared: \.shared, isOwnSharedContribution: \.ownContribution)
            let state = DayMediaTabs(items: body, featuredEnabled: true,
                                     featured: { _ in true }, category: \.category)
            XCTAssertEqual(state.items(inTab: .featured).map(\.id), includeShared ? ["own", "shared"] : ["own"])
        }
    }

    func testNewScoresDoNotStealTheCurrentTabSelection() {
        let source = [Item(id: "a", category: .photoVideo)]
        let before = DayMediaTabs(items: source, featuredEnabled: true, category: \.category)
        let after = DayMediaTabs(items: source, featuredEnabled: true,
                                 featured: { _ in true }, category: \.category)
        XCTAssertEqual(after.tabSelection(preserving: before.tabSelection(preserving: .photoVideo)), .photoVideo)
        XCTAssertEqual(after.tabSelection(preserving: .featured), .featured)
        XCTAssertEqual(after.items(inTab: .featured).map(\.id), ["a"])
    }
}
