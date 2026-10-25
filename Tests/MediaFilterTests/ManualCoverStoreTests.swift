import XCTest
@testable import MediaFilter

final class ManualCoverStoreTests: XCTestCase {
    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "manual-cover-tests-\(UUID().uuidString)"
        suiteName = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int,
                        _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        return utc.date(from: parts)!
    }

    func testDayKeyFollowsCalendarZone() {
        // 23:30 on May 4 UTC is already May 5 in Tokyo (UTC+9).
        let date = utcDate(2024, 5, 4, 23, 30)
        XCTAssertEqual(ManualCoverStore.dayKey(for: date, calendar: utc), "2024-05-04")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ManualCoverStore.dayKey(for: date, calendar: tokyo), "2024-05-05")
    }

    func testSetAndReadCoverPerDay() {
        let store = ManualCoverStore(defaults: makeDefaults())
        let day = utcDate(2024, 5, 4)
        XCTAssertNil(store.coverID(for: day, calendar: utc))
        store.setCover("asset-1", for: day, calendar: utc)
        XCTAssertEqual(store.coverID(for: day, calendar: utc), "asset-1")
    }

    func testDaysAreIndependent() {
        let store = ManualCoverStore(defaults: makeDefaults())
        let first = utcDate(2024, 5, 4)
        let second = utcDate(2024, 5, 5)
        store.setCover("asset-1", for: first, calendar: utc)
        store.setCover("asset-2", for: second, calendar: utc)
        XCTAssertEqual(store.coverID(for: first, calendar: utc), "asset-1")
        XCTAssertEqual(store.coverID(for: second, calendar: utc), "asset-2")
    }

    func testOverwriteReplacesPreviousCover() {
        let store = ManualCoverStore(defaults: makeDefaults())
        let day = utcDate(2024, 5, 4)
        store.setCover("asset-1", for: day, calendar: utc)
        store.setCover("asset-2", for: day, calendar: utc)
        XCTAssertEqual(store.coverID(for: day, calendar: utc), "asset-2")
    }

    func testClearRemovesOnlyThatDay() {
        let store = ManualCoverStore(defaults: makeDefaults())
        let first = utcDate(2024, 5, 4)
        let second = utcDate(2024, 5, 5)
        store.setCover("asset-1", for: first, calendar: utc)
        store.setCover("asset-2", for: second, calendar: utc)
        store.clear(for: first, calendar: utc)
        XCTAssertNil(store.coverID(for: first, calendar: utc))
        XCTAssertEqual(store.coverID(for: second, calendar: utc), "asset-2")
    }

    func testClearWithoutRecordIsNoOp() {
        let store = ManualCoverStore(defaults: makeDefaults())
        let day = utcDate(2024, 5, 4)
        store.clear(for: day, calendar: utc)
        XCTAssertNil(store.coverID(for: day, calendar: utc))
    }

    func testRecordsPersistAcrossStoreInstances() {
        let defaults = makeDefaults()
        let day = utcDate(2024, 5, 4)
        ManualCoverStore(defaults: defaults).setCover("asset-1", for: day, calendar: utc)
        XCTAssertEqual(
            ManualCoverStore(defaults: defaults).coverID(for: day, calendar: utc), "asset-1")
    }
}
