import XCTest
@testable import MediaFilter

final class CoverRelativeCaptionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func caption(_ day: Date, now: Date) -> String {
        CoverRelativeCaption.text(for: day, now: now, calendar: calendar)
    }

    func testSameDayIsToday() {
        XCTAssertEqual(caption(date(2026, 10, 24, hour: 1), now: date(2026, 10, 24, hour: 23)), "今天")
    }

    func testPreviousCalendarDayIsYesterdayEvenWithinHours() {
        XCTAssertEqual(caption(date(2026, 10, 23, hour: 23), now: date(2026, 10, 24, hour: 1)), "昨天")
    }

    func testDaysBeforeOneMonth() {
        XCTAssertEqual(caption(date(2026, 10, 22), now: date(2026, 10, 24)), "2天前")
        XCTAssertEqual(caption(date(2026, 10, 18), now: date(2026, 10, 24)), "6天前")
        XCTAssertEqual(caption(date(2026, 9, 25), now: date(2026, 10, 24)), "4周前")
    }

    func testWeeksDoNotRoundUp() {
        XCTAssertEqual(caption(date(2026, 10, 17), now: date(2026, 10, 24)), "1周前")
        XCTAssertEqual(caption(date(2026, 10, 11), now: date(2026, 10, 24)), "1周前")
        XCTAssertEqual(caption(date(2026, 10, 10), now: date(2026, 10, 24)), "2周前")
    }

    func testMonthsBeforeOneYear() {
        XCTAssertEqual(caption(date(2026, 9, 24), now: date(2026, 10, 24)), "1个月前")
        XCTAssertEqual(caption(date(2025, 10, 25), now: date(2026, 10, 24)), "11个月前")
    }

    func testYearsDoNotRoundUp() {
        XCTAssertEqual(caption(date(2025, 10, 24), now: date(2026, 10, 24)), "1年前")
        XCTAssertEqual(caption(date(2024, 3, 31), now: date(2026, 3, 30)), "1年前")
        XCTAssertEqual(caption(date(2024, 3, 31), now: date(2026, 10, 24)), "2年前")
    }

}
