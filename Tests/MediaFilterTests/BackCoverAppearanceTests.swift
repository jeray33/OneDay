import Foundation
import XCTest
@testable import MediaFilter

final class BackCoverAppearanceTests: XCTestCase {
    func testOptionsAndOrder() {
        XCTAssertEqual(BackCoverBackground.allCases, [.paper, .bright, .immersive])
        XCTAssertEqual(BackCoverBackground.allCases.map(\.label), ["浅灰", "明快", "沉静"])
    }

    func testDefaultKeepsExistingImmersiveAppearance() {
        for value in [nil, "", "invalid", "white", "black", "tinted"] {
            XCTAssertEqual(BackCoverBackground(savedValue: value), .immersive)
        }
    }

    func testLightColorsUseContentBackgrounds() {
        XCTAssertEqual(BackCoverBackground.paper.pageBackground, .paper)
        XCTAssertEqual(BackCoverBackground.bright.pageBackground, .bright)
        XCTAssertNil(BackCoverBackground.immersive.pageBackground)
    }

    func testSelectionsPersistIndependentlyAndSurviveLegacyCleanup() {
        let suite = "BackCoverAppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PreviewBackground.immersive.rawValue, forKey: PreviewBackground.storageKey)
        for content in PageBackground.allCases {
            defaults.set(content.rawValue, forKey: "OneDay.pageBackground")
            for back in BackCoverBackground.allCases {
                defaults.set(back.rawValue, forKey: BackCoverBackground.storageKey)
                defaults.set("white", forKey: "OneDay.backCoverBackground")
                DayAppearancePreferences.migrateLegacySettings(in: defaults)
                DayAppearancePreferences.migrateLegacySettings(in: defaults)
                XCTAssertEqual(BackCoverBackground(savedValue: defaults.string(forKey: BackCoverBackground.storageKey)),
                               back)
                XCTAssertEqual(PageBackground(savedValue: defaults.string(forKey: "OneDay.pageBackground")), content)
                XCTAssertEqual(defaults.string(forKey: PreviewBackground.storageKey), PreviewBackground.immersive.rawValue)
                XCTAssertNil(defaults.object(forKey: "OneDay.backCoverBackground"))
            }
        }
    }
}
