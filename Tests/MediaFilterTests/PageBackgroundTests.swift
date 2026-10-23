import Foundation
import XCTest
@testable import MediaFilter

final class PageBackgroundTests: XCTestCase {
    func testOnlyRetainedBackgroundsAreSelectable() {
        XCTAssertEqual(PageBackground.allCases, [.paper, .pureWhite, .bright])
        XCTAssertEqual(PageBackground.allCases.map(\.label), ["白色", "纯白色", "明快"])
    }

    func testRetainedSelectionsKeepTheirStoredIdentity() {
        for background in PageBackground.allCases {
            XCTAssertEqual(PageBackground(savedValue: background.rawValue), background)
        }
        XCTAssertEqual(PageBackground.bright.rawValue, "bright2")
    }

    func testRemovedAndInvalidBackgroundsFallBackToWhite() {
        for value in ["dark", "warm", "dominant", "vibrant", "bright", "unknown", ""] {
            XCTAssertEqual(PageBackground(savedValue: value), .paper)
        }
        XCTAssertEqual(PageBackground(savedValue: nil), .paper)
    }

    func testMigrationClearsRemovedModesAndPreservesUnrelatedSettings() {
        let suite = "PageBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let obsolete = [
            "OneDay.coverBackgroundMode": "vibrant",
            "OneDay.coverMode": "scattered",
            "OneDay.photoLayoutMode": "magazine",
            "OneDay.enabledTemplates": "collage,stack",
            "OneDay.borderStyle": "polaroid",
            "OneDay.scrollStagger": "bold"
        ]
        for (key, value) in obsolete { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: "OneDay.sharedContributorMatch")
        defaults.set("dark", forKey: "OneDay.pageBackground")
        defaults.set("thin", forKey: "OneDay.borderWidth")
        defaults.set(false, forKey: "OneDay.includeSharedAlbums")
        DayAppearancePreferences.migrateLegacySettings(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "OneDay.pageBackground"), "paper")
        for key in obsolete.keys { XCTAssertNil(defaults.object(forKey: key)) }
        XCTAssertNil(defaults.object(forKey: "OneDay.sharedContributorMatch"))
        XCTAssertEqual(defaults.string(forKey: "OneDay.borderWidth"), "thin")
        XCTAssertEqual(defaults.object(forKey: "OneDay.includeSharedAlbums") as? Bool, false)
        defaults.set("bright2", forKey: "OneDay.pageBackground")
        DayAppearancePreferences.migrateLegacySettings(in: defaults)
        DayAppearancePreferences.migrateLegacySettings(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "OneDay.pageBackground"), "bright2")
    }
}
