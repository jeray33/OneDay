import XCTest
@testable import MediaFilter

final class HistorySelectionPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testNewAndReorderedAssetsDoNotReplaceSelectedPhotos() {
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(
            previous: ["b", "d", "f"], available: ["a", "f", "e", "d", "c", "b"], limit: 3),
            ["b", "d", "f"])
    }

    func testOnlyDeletedSelectionsAreReplaced() {
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(
            previous: ["b", "d", "f"], available: ["a", "b", "c", "f"], limit: 3),
            ["b", "f", "a"])
    }

    func testInitialSelectionAndShortDaysAreDeterministic() {
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(
            previous: [], available: ["a", "b", "c", "d"], limit: 3), ["a", "b", "c"])
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(
            previous: ["deleted"], available: ["a"], limit: 3), ["a"])
    }

    func testDuplicatesEmptyDaysAndLimits() {
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(
            previous: ["a", "a"], available: ["a", "b", "b"], limit: 3), ["a", "b"])
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(previous: ["a"], available: [], limit: 3), [])
        XCTAssertEqual(HistorySelectionPolicy.selectedIDs(previous: [], available: ["a"], limit: 0), [])
    }

    func testLeapDaySkipsNonLeapYearsWithoutMarchFallback() {
        let days = HistorySelectionPolicy.matchingDays(
            referenceDate: day(2024, 2, 29), earliest: day(2019, 1, 1),
            latest: day(2025, 12, 31), calendar: calendar)
        XCTAssertEqual(days, [day(2024, 2, 29), day(2020, 2, 29)])
    }

    func testYearBoundaryStaysOnSameCalendarDay() {
        XCTAssertEqual(HistorySelectionPolicy.matchingDays(
            referenceDate: day(2024, 1, 1), earliest: day(2022, 12, 31),
            latest: day(2024, 1, 1), calendar: calendar),
            [day(2024, 1, 1), day(2023, 1, 1), day(2022, 1, 1)])
    }

    func testDSTDatesUseCalendarMidnights() {
        let dates = HistorySelectionPolicy.matchingDays(
            referenceDate: day(2024, 3, 10), earliest: day(2022, 1, 1),
            latest: day(2024, 12, 31), calendar: calendar)
        XCTAssertEqual(dates, [day(2024, 3, 10), day(2023, 3, 10), day(2022, 3, 10)])
        for date in dates { XCTAssertEqual(calendar.startOfDay(for: date), date) }
    }

    func testInvertedDateBoundsHaveNoDays() {
        XCTAssertEqual(HistorySelectionPolicy.matchingDays(
            referenceDate: day(2024, 1, 1), earliest: day(2025, 1, 1),
            latest: day(2024, 1, 1), calendar: calendar), [])
    }
}
