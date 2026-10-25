import Foundation
import Photos
import XCTest
@testable import MediaFilter

final class DayMediaScopeTests: XCTestCase {
    private struct Item {
        let id: String
        let type: PHAssetMediaType
        var category: MediaCategory
        var shared = false
        var ownContribution = false
        var hidden = false
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func editorial(_ items: [Item]) -> [Item] {
        DayMediaScope.editorialItems(
            from: items, mediaType: \.type, isOwnSharedContribution: \.ownContribution)
    }

    private var items: [Item] {
        [
            Item(id: "photo", type: .image, category: .photoVideo),
            Item(id: "video", type: .video, category: .photoVideo),
            Item(id: "screenshot", type: .image, category: .screenshot),
            Item(id: "recording", type: .video, category: .screenshot),
            Item(id: "panorama", type: .image, category: .photoVideo),
            Item(id: "other", type: .image, category: .otherImage)
        ]
    }

    private func sharedCount(_ items: [Item], duplicates: Set<String> = []) -> Int {
        DayMediaScope.friendSharedCount(
            from: items, excluding: duplicates, id: \.id,
            isForeignShared: { $0.shared && !$0.ownContribution }, isHidden: \.hidden)
    }

    func testFriendSharedCountExcludesOwnContributionsHiddenAssetsAndDuplicateIdentifiers() {
        let friend = Item(id: "friend", type: .image, category: .photoVideo, shared: true)
        let source = [
            items[0], friend, friend,
            Item(id: "own-upload", type: .image, category: .photoVideo,
                 shared: true, ownContribution: true),
            Item(id: "hidden", type: .image, category: .photoVideo,
                 shared: true, hidden: true)
        ]
        XCTAssertEqual(sharedCount(source), 1)
        XCTAssertEqual(sharedCount([]), 0)
    }

    func testFriendSharedCountUsesVerifiedVideoDuplicatesInsteadOfVideoMetadata() {
        let source = [
            Item(id: "original", type: .video, category: .photoVideo),
            Item(id: "shared-copy", type: .video, category: .photoVideo, shared: true),
            Item(id: "different-video", type: .video, category: .photoVideo, shared: true)
        ]
        XCTAssertEqual(sharedCount(source), 2)
        XCTAssertEqual(sharedCount(source, duplicates: ["shared-copy"]), 1)
        XCTAssertEqual(sharedCount(source, duplicates: ["original"]), 2)
    }

    func testFriendSharedCountDoesNotDependOnClassificationOrFolding() {
        var source = items.map { item in
            var shared = item
            shared.shared = true
            return shared
        }
        XCTAssertEqual(sharedCount(source), items.count)
        source[0].category = .screenshot
        source[1].category = .otherImage
        XCTAssertEqual(sharedCount(source), items.count)
        XCTAssertEqual(sharedCount(Array(source.dropFirst())), items.count - 1)
    }

    func testAllBodyTabsLeaveCompleteEditorialInventoryIntact() {
        let expected = items.map(\.id)
        let tabs = DayMediaTabs(items: items, category: { $0.category })
        for category in tabs.availableCategories {
            XCTAssertTrue(tabs.items(in: category).allSatisfy { $0.category == category })
            XCTAssertEqual(editorial(items).map(\.id), expected)
            XCTAssertEqual(editorial(items).filter { $0.type == .image }.count, 4)
            XCTAssertEqual(editorial(items).filter { $0.type == .video }.count, 2)
        }
    }

    func testEditorialSharedPolicyDoesNotFollowBodySharedToggles() {
        let source = [
            Item(id: "original", type: .image, category: .photoVideo),
            Item(id: "duplicate", type: .image, category: .photoVideo, shared: true, ownContribution: true),
            Item(id: "foreign", type: .image, category: .photoVideo, shared: true)
        ]
        for includeShared in [false, true] {
            let body = DayMediaScope.bodyItems(
                from: source, includeShared: includeShared,
                isShared: \.shared, isOwnSharedContribution: \.ownContribution)
            XCTAssertEqual(editorial(source).map(\.id), ["original", "foreign"])
            XCTAssertEqual(body.map(\.id), includeShared ? ["original", "foreign"] : ["original"])
        }
    }

    func testOwnSharedCopiesAreExcludedForEveryMediaCategory() {
        for category in MediaCategory.allCases {
            let source = [
                Item(id: "original", type: .image, category: category),
                Item(id: "duplicate", type: .image, category: category, shared: true, ownContribution: true),
                Item(id: "foreign", type: .image, category: category, shared: true)
            ]
            let body = DayMediaScope.bodyItems(
                from: source, includeShared: true,
                isShared: \.shared, isOwnSharedContribution: \.ownContribution)
            XCTAssertEqual(body.map(\.id), ["original", "foreign"])
        }
    }

    func testClassificationCorrectionsDoNotChangeEditorialCandidates() {
        var source = items
        let before = editorial(source).map(\.id)
        source[0].category = .otherImage
        source[5].category = .photoVideo
        XCTAssertEqual(editorial(source).map(\.id), before)
    }

    func testUnsupportedAssetsAreExcludedWithoutCategoryClassification() {
        XCTAssertTrue(DayMediaScope.isSupported(.image))
        XCTAssertTrue(DayMediaScope.isSupported(.video))
        XCTAssertFalse(DayMediaScope.isSupported(.audio))
        XCTAssertFalse(DayMediaScope.isSupported(.unknown))
        let source = items + [
            Item(id: "audio", type: .audio, category: .photoVideo),
            Item(id: "unknown", type: .unknown, category: .photoVideo)
        ]
        XCTAssertEqual(editorial(source).map(\.id), items.map(\.id))
    }

    func testNavigationPreservesExistingPastDayBoundary() {
        let today = date(2026, 10, 19, hour: 12)
        XCTAssertEqual(
            DayMediaScope.navigationDay(for: date(2026, 10, 18, hour: 23), today: today, calendar: calendar),
            date(2026, 10, 18))
        XCTAssertNil(DayMediaScope.navigationDay(for: today, today: today, calendar: calendar))
        XCTAssertNil(DayMediaScope.navigationDay(for: date(2026, 10, 20), today: today, calendar: calendar))
        XCTAssertNil(DayMediaScope.navigationDay(for: nil, today: today, calendar: calendar))
    }

    func testPreviousAndNextDoNotSkipDaysWithNoBodyMatches() {
        let categories: [MediaCategory] = [.photoVideo, .screenshot, .photoVideo, .otherImage, .photoVideo]
        let source = categories.enumerated().map { (date(2026, 10, 10 + $0.offset), $0.element) }
        let days = source.compactMap {
            DayMediaScope.navigationDay(for: $0.0, today: date(2026, 10, 19), calendar: calendar)
        }.sorted(by: >)
        for category in MediaCategory.allCases {
            let bodyDates = source.filter { $0.1 == category }.map(\.0)
            XCTAssertLessThan(bodyDates.count, days.count)
            XCTAssertEqual(
                DayMediaScope.previousDay(before: date(2026, 10, 12, hour: 15), in: days, calendar: calendar),
                date(2026, 10, 11))
            XCTAssertEqual(
                DayMediaScope.nextDay(after: date(2026, 10, 12, hour: 15), in: days, calendar: calendar),
                date(2026, 10, 13))
        }
        XCTAssertNil(DayMediaScope.previousDay(before: date(2026, 10, 10), in: days, calendar: calendar))
        XCTAssertNil(DayMediaScope.nextDay(after: date(2026, 10, 14), in: days, calendar: calendar))
    }

    func testHistoryMatchesCalendarDayAcrossYearsAndKeepsCurrentYear() {
        let reference = date(2026, 10, 19, hour: 12)
        for year in [2020, 2025, 2026] {
            XCTAssertEqual(
                DayMediaScope.historyDay(for: date(year, 10, 19, hour: 23), referenceDate: reference, calendar: calendar),
                date(year, 10, 19))
        }
        XCTAssertNil(DayMediaScope.historyDay(for: date(2025, 9, 19), referenceDate: reference, calendar: calendar))
        XCTAssertNil(DayMediaScope.historyDay(for: date(2025, 10, 18), referenceDate: reference, calendar: calendar))
        XCTAssertNil(DayMediaScope.historyDay(for: nil, referenceDate: reference, calendar: calendar))
    }

    func testHistoryLeapDayDoesNotFallBackToFebruary28() {
        let reference = date(2024, 2, 29)
        XCTAssertEqual(
            DayMediaScope.historyDay(for: date(2020, 2, 29, hour: 9), referenceDate: reference, calendar: calendar),
            date(2020, 2, 29))
        XCTAssertNil(DayMediaScope.historyDay(for: date(2023, 2, 28), referenceDate: reference, calendar: calendar))
    }
}
