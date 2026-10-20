import XCTest
@testable import MediaFilter

final class TitleSegmentationPolicyTests: XCTestCase {
    private struct Item: Equatable {
        let id: Int
        let band: Int
    }

    private let items = [
        Item(id: 1, band: 1), Item(id: 2, band: 1),
        Item(id: 3, band: 3), Item(id: 4, band: 3),
        Item(id: 5, band: 5)
    ]

    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let name = "TitleSegmentationPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    func testDefaultsPreservePlacePriorityAndTimeFallback() {
        withDefaults { defaults in
            let policy = TitleSegmentationPolicy(defaults: defaults)
            XCTAssertTrue(policy.placeEnabled)
            XCTAssertFalse(policy.nestedTimeEnabled)
            XCTAssertTrue(policy.timeEnabled)
        }
    }

    func testEverySwitchCombinationWithZeroOneAndMultiplePlaces() {
        withDefaults { defaults in
            for mask in 0..<8 {
                var policy = TitleSegmentationPolicy(defaults: defaults)
                policy.placeEnabled = mask & 1 != 0
                policy.nestedTimeEnabled = mask & 2 != 0
                policy.timeEnabled = mask & 4 != 0
                for count in 0...2 {
                    let places: [(name: String?, items: [Item])]
                    switch count {
                    case 0: places = []
                    case 1: places = [("公园", items)]
                    default:
                        places = [("公园", Array(items.prefix(3))),
                                  ("商场", Array(items.suffix(2)))]
                    }
                    let groups = policy.groups(items: items, places: places, timeBand: \.band)
                    XCTAssertEqual(groups.flatMap(\.items), items, "mask \(mask), places \(count)")
                    let usesPlaces = policy.placeEnabled && count >= 2
                    if usesPlaces {
                        XCTAssertEqual(groups.filter(\.showsPlaceHeading).map(\.placeName),
                                       ["公园", "商场"])
                        XCTAssertEqual(groups.count, policy.nestedTimeEnabled ? 4 : 2)
                        XCTAssertEqual(groups.compactMap(\.timeBand),
                                       policy.nestedTimeEnabled ? [1, 3, 3, 5] : [])
                    } else {
                        XCTAssertTrue(groups.allSatisfy { $0.placeName == nil && !$0.showsPlaceHeading })
                        XCTAssertEqual(groups.count, policy.timeEnabled ? 3 : 1)
                        XCTAssertEqual(groups.compactMap(\.timeBand),
                                       policy.timeEnabled ? [1, 3, 5] : [])
                    }
                }
            }
        }
    }

    func testUnknownPlacesUseNumberedNamesAndReturnVisitsStaySeparate() {
        withDefaults { defaults in
            var policy = TitleSegmentationPolicy(defaults: defaults)
            policy.nestedTimeEnabled = true
            let places: [(name: String?, items: [Item])] = [
                ("公园", [items[0]]), (nil, [items[1], items[2]]),
                ("公园", [items[3]]), ("", [items[4]])
            ]
            let groups = policy.groups(items: items, places: places, timeBand: \.band)
            XCTAssertEqual(groups.filter(\.showsPlaceHeading).compactMap(\.placeName),
                           ["公园", "地点 2", "公园", "地点 4"])
            XCTAssertEqual(groups.flatMap(\.items), items)
        }
    }

    func testPreferencesRestoreAndHiddenNestedChoiceIsRetained() {
        withDefaults { defaults in
            var policy = TitleSegmentationPolicy(defaults: defaults)
            policy.nestedTimeEnabled = true
            policy.placeEnabled = false
            policy.timeEnabled = false
            policy.save(to: defaults)
            var restored = TitleSegmentationPolicy(defaults: defaults)
            XCTAssertFalse(restored.placeEnabled)
            XCTAssertFalse(restored.timeEnabled)
            XCTAssertTrue(restored.nestedTimeEnabled)
            restored.placeEnabled = true
            restored.save(to: defaults)
            XCTAssertTrue(TitleSegmentationPolicy(defaults: defaults).nestedTimeEnabled)
        }
    }

    func testEmptyDaysAndEmptyPlaceGroupsDoNotCreateSections() {
        withDefaults { defaults in
            let policy = TitleSegmentationPolicy(defaults: defaults)
            let empty: [Item] = []
            XCTAssertTrue(policy.groups(items: empty, places: [], timeBand: \.band).isEmpty)
            let groups = policy.groups(
                items: items, places: [("空", []), ("公园", items)], timeBand: \.band)
            XCTAssertEqual(groups.compactMap(\.timeBand), [1, 3, 5])
            XCTAssertTrue(groups.allSatisfy { $0.placeName == nil })
        }
    }
}
