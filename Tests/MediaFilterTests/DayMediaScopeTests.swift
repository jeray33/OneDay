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
            for contributorMatch in [false, true] {
                let body = source.filter {
                    if !includeShared { return !$0.shared }
                    return !contributorMatch || !$0.ownContribution
                }
                XCTAssertEqual(editorial(source).map(\.id), ["original", "foreign"])
                if !includeShared { XCTAssertEqual(body.map(\.id), ["original"]) }
                if includeShared && !contributorMatch { XCTAssertEqual(body.count, 3) }
            }
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
