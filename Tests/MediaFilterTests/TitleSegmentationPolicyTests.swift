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
                    let places: [(id: String, name: String?, items: [Item])]
                    switch count {
                    case 0: places = []
                    case 1: places = [(id: "p1", name: "公园", items: items)]
                    default:
                        places = [(id: "p1", name: "公园", items: Array(items.prefix(3))),
                                  (id: "p2", name: "商场", items: Array(items.suffix(2)))]
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

    func testUnresolvedPlacesPassNoNameAndReturnVisitsStaySeparate() {
        withDefaults { defaults in
            var policy = TitleSegmentationPolicy(defaults: defaults)
            policy.nestedTimeEnabled = true
            // Unresolved stops pass `name == nil`; the heading layer reserves
            // space instead of inventing "地点 N" in the data model.
            let places: [(id: String, name: String?, items: [Item])] = [
                (id: "p1", name: "公园", items: [items[0]]),
                (id: "p2", name: nil, items: [items[1], items[2]]),
                (id: "p3", name: "公园", items: [items[3]]),
                (id: "p4", name: "", items: [items[4]])
            ]
            let groups = policy.groups(items: items, places: places, timeBand: \.band)
            XCTAssertEqual(groups.filter(\.showsPlaceHeading).map(\.placeName),
                           ["公园", nil, "公园", nil])
            XCTAssertEqual(groups.map(\.placeID),
                           ["p1", "p2", "p2", "p3", "p4"])
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
                items: items, places: [(id: "e", name: "空", items: []), (id: "p", name: "公园", items: items)],
                timeBand: \.band)
            XCTAssertEqual(groups.compactMap(\.timeBand), [1, 3, 5])
            XCTAssertTrue(groups.allSatisfy { $0.placeName == nil })
        }
    }
}
