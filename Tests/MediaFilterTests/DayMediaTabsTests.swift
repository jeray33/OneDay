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
            for contributorMatch in [false, true] {
                let body = source.filter {
                    if !includeShared { return !$0.shared }
                    return !contributorMatch || !$0.ownContribution
                }
                let state = tabs(body)
                XCTAssertEqual(state.availableCategories.contains(.screenshot), includeShared)
                XCTAssertEqual(state.availableCategories.contains(.otherImage), includeShared && !contributorMatch)
                XCTAssertEqual(state.selection(preserving: .otherImage),
                               includeShared && !contributorMatch ? .otherImage : .photoVideo)
            }
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
}
