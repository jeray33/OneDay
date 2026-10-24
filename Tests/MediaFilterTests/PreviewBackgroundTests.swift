import Foundation
import XCTest
@testable import MediaFilter

final class PreviewBackgroundTests: XCTestCase {
    func testDefaultsToFollowingDay() {
        for value in [nil, "", "invalid", "white", "dark"] {
            XCTAssertEqual(PreviewBackground(savedValue: value), .day)
        }
    }

    func testOnlyDayAndImmersiveAreSelectable() {
        XCTAssertEqual(PreviewBackground.allCases, [.day, .immersive])
        XCTAssertEqual(PreviewBackground.allCases.map(\.label), ["跟随当天页", "沉浸深色"])
    }

    func testSelectionsRestoreWithoutChangingDayBackground() {
        let suite = "PreviewBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for day in PageBackground.allCases {
            defaults.set(day.rawValue, forKey: "OneDay.pageBackground")
            for preview in PreviewBackground.allCases {
                defaults.set(preview.rawValue, forKey: PreviewBackground.storageKey)
                XCTAssertEqual(PreviewBackground(savedValue: defaults.string(forKey: PreviewBackground.storageKey)),
                               preview)
                XCTAssertEqual(PageBackground(savedValue: defaults.string(forKey: "OneDay.pageBackground")), day)
            }
        }
    }

    func testDaySettingsMigrationPreservesPreviewChoice() {
        let suite = "PreviewBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PreviewBackground.immersive.rawValue, forKey: PreviewBackground.storageKey)
        DayAppearancePreferences.migrateLegacySettings(in: defaults)
        XCTAssertEqual(PreviewBackground(savedValue: defaults.string(forKey: PreviewBackground.storageKey)),
                       .immersive)
    }
}
