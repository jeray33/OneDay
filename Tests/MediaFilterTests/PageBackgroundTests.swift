import Foundation
import XCTest
@testable import MediaFilter

final class PageBackgroundTests: XCTestCase {
    func testOnlyRetainedBackgroundsAreSelectable() {
        XCTAssertEqual(PageBackground.allCases, [.pureWhite, .paper, .bright])
        XCTAssertEqual(PageBackground.allCases.map(\.label), ["白色", "浅灰", "明快"])
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
            "OneDay.coverStyle": "minimal",
            "OneDay.backCoverBackground": "white",
            "OneDay.backCoverTransition": "reveal",
            "OneDay.backCoverReducedMotion": "followThenFade",
            "OneDay.coverBackgroundMode": "vibrant",
            "OneDay.coverMode": "scattered",
            "OneDay.photoLayoutMode": "magazine",
            "OneDay.enabledTemplates": "collage,stack",
            "OneDay.borderStyle": "polaroid",
            "OneDay.scrollStagger": "bold",
            "OneDay.scrollScale": "extreme",
            "OneDay.scrollMovement": "huge",
            "OneDay.scrollRotation": "bold",
            "OneDay.scrollFade": "hidden",
            "OneDay.scrollSpring": "bouncy",
            "OneDay.scrollBlur": "heavy",
            "OneDay.scrollParallax": "strong",
            "OneDay.scrollTiltX": "bold",
            "OneDay.scrollTiltY": "bold",
            "OneDay.scrollTiltDecay": "edge",
            "OneDay.rewindMode": "flash"
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

    func testLegacyRewindModeIsDiscardedWithoutChangingTunnelSettings() {
        let suite = "PageBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("random", forKey: "OneDay.rewindSortOrder")
        defaults.set("photo", forKey: "OneDay.tunnelTapMode")
        for mode in ["flash", "rewind", "invalid"] {
            defaults.set(mode, forKey: "OneDay.rewindMode")
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            XCTAssertNil(defaults.object(forKey: "OneDay.rewindMode"))
            XCTAssertEqual(defaults.string(forKey: "OneDay.rewindSortOrder"), "random")
            XCTAssertEqual(defaults.string(forKey: "OneDay.tunnelTapMode"), "photo")
        }
    }

    func testRemovedCoverChoicesAreDiscardedForAllSavedModes() {
        let suite = "PageBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("bright2", forKey: "OneDay.pageBackground")
        defaults.set("impact", forKey: "OneDay.coverDateFont")
        for value in ["minimal", "photo", "tinted", "white", "gray", "black",
                      "immersive", "reveal", "sync", "invalid"] {
            for key in ["OneDay.coverStyle", "OneDay.backCoverBackground", "OneDay.backCoverTransition"] {
                defaults.set(value, forKey: key)
            }
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            for key in ["OneDay.coverStyle", "OneDay.backCoverBackground", "OneDay.backCoverTransition"] {
                XCTAssertNil(defaults.object(forKey: key))
            }
            XCTAssertEqual(defaults.string(forKey: "OneDay.pageBackground"), "bright2")
            XCTAssertEqual(defaults.string(forKey: "OneDay.coverDateFont"), "impact")
        }
    }
}
