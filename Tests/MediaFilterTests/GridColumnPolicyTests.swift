import XCTest
@testable import MediaFilter

final class GridColumnPolicyTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let name = "GridColumnPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        test(defaults)
    }

    func testAutomaticBoundaries() {
        withDefaults { defaults in
            for (total, expected) in [(0, 1), (19, 1), (20, 2), (50, 2), (51, 3)] {
                let policy = GridColumnPolicy(itemCount: total, defaults: defaults)
                XCTAssertEqual(policy.mode, .automatic)
                XCTAssertEqual(policy.columnCount, expected)
            }
        }
    }

    func testManualCountsPersistAcrossDaysAndAutomaticKeepsManualChoice() {
        withDefaults { defaults in
            for count in 1...6 {
                var policy = GridColumnPolicy(itemCount: 19, defaults: defaults)
                policy.selectManual(count)
                policy.save(to: defaults)
                var nextDay = GridColumnPolicy(itemCount: 51, defaults: defaults)
                XCTAssertEqual(nextDay.mode, .manual)
                XCTAssertEqual(nextDay.columnCount, count)
                nextDay.mode = .automatic
                XCTAssertEqual(nextDay.columnCount, 3)
                nextDay.save(to: defaults)
                var restored = GridColumnPolicy(itemCount: 20, defaults: defaults)
                XCTAssertEqual(restored.columnCount, 2)
                XCTAssertEqual(restored.manualCount, count)
                restored.mode = .manual
                XCTAssertEqual(restored.columnCount, count)
            }
        }
    }

    func testInvalidAndLegacySettings() {
        withDefaults { defaults in
            defaults.set(6, forKey: GridColumnPolicy.countKey)
            XCTAssertEqual(GridColumnPolicy(itemCount: 19, defaults: defaults).mode, .automatic)
            defaults.set("invalid", forKey: GridColumnPolicy.modeKey)
            XCTAssertEqual(GridColumnPolicy(itemCount: 19, defaults: defaults).columnCount, 1)
            defaults.set("manual", forKey: GridColumnPolicy.modeKey)
            for count in [-1, 0, 7] {
                defaults.set(count, forKey: GridColumnPolicy.countKey)
                XCTAssertEqual(GridColumnPolicy(itemCount: 20, defaults: defaults).columnCount, 2)
            }
            var policy = GridColumnPolicy(itemCount: 20, defaults: defaults)
            policy.selectManual(99)
            XCTAssertEqual(policy.columnCount, 6)
            policy.selectManual(-1)
            XCTAssertEqual(policy.columnCount, 1)
        }
    }
}
