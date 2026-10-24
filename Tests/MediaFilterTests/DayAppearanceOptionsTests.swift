import Foundation
import XCTest
@testable import MediaFilter

final class DayAppearanceOptionsTests: XCTestCase {
    func testTitleSizesShowActualPointsAndKeepExistingValues() {
        XCTAssertEqual(SectionTitleSize.allCases.map(\.size), [14, 20, 26, 32, 38])
        XCTAssertEqual(SectionTitleSize.allCases.map(\.label), ["14 pt", "20 pt", "26 pt", "32 pt", "38 pt"])
    }

    func testCornerRadiiShowActualPointsAndKeepExistingValues() {
        XCTAssertEqual(PhotoCornerRadius.allCases.map(\.value), [0, 4, 8, 14, 22, 32])
        XCTAssertEqual(PhotoCornerRadius.allCases.map(\.label), ["0 pt", "4 pt", "8 pt", "14 pt", "22 pt", "32 pt"])
    }

    func testBordersShowActualScaleWithoutChangingLayoutWidths() {
        XCTAssertEqual(PhotoBorderWidth.allCases.map(\.scale), [0, 0.33, 0.56, 0.78, 1])
        XCTAssertEqual(PhotoBorderWidth.allCases.map(\.label), ["0%", "33%", "56%", "78%", "100%"])
    }

    func testShadowsShowActualScaleWithoutChangingRendering() {
        XCTAssertEqual(PhotoShadowLevel.allCases.map(\.scale), [0, 0.15, 0.28, 0.42, 0.58, 0.72, 0.86, 1])
        XCTAssertEqual(PhotoShadowLevel.allCases.map(\.label), ["0%", "15%", "28%", "42%", "58%", "72%", "86%", "100%"])
    }

    func testNumericLabelsPreserveStoredSelectionIdentities() {
        let titles = ["xsmall", "small", "medium", "large", "xlarge"]
        let corners = ["none", "slight", "small", "medium", "large", "xlarge"]
        let borders = ["none", "thin", "medium", "thick", "max"]
        let shadows = ["none", "extraFine", "fine", "small", "medium", "mediumLarge", "large", "max"]
        XCTAssertEqual(titles.compactMap(SectionTitleSize.init(rawValue:)), SectionTitleSize.allCases)
        XCTAssertEqual(corners.compactMap(PhotoCornerRadius.init(rawValue:)), PhotoCornerRadius.allCases)
        XCTAssertEqual(borders.compactMap(PhotoBorderWidth.init(rawValue:)), PhotoBorderWidth.allCases)
        XCTAssertEqual(shadows.compactMap(PhotoShadowLevel.init(rawValue:)), PhotoShadowLevel.allCases)
    }

    func testRemovedChromeSettingsAreClearedWithoutChangingRetainedPreferences() {
        let suite = "DayAppearanceOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let removed = ["OneDay.bottomToolbar", "OneDay.dayScrollIndicator", "OneDay.textDayNavigation"]
        let retained = [
            "OneDay.sectionTitleSize": SectionTitleSize.medium.rawValue,
            "OneDay.photoCornerRadius": PhotoCornerRadius.large.rawValue,
            "OneDay.borderWidth": PhotoBorderWidth.thin.rawValue,
            "OneDay.photoShadow": PhotoShadowLevel.fine.rawValue
        ]
        for (key, value) in retained { defaults.set(value, forKey: key) }
        defaults.set(false, forKey: "OneDay.scrubberSectionMarks")
        defaults.set(false, forKey: "OneDay.scrubberTickHaptics")
        defaults.set(true, forKey: "OneDay.photoCaptions")
        for mask in 0..<8 {
            for (index, key) in removed.enumerated() {
                defaults.set(mask & (1 << index) != 0, forKey: key)
            }
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            for key in removed { XCTAssertNil(defaults.object(forKey: key)) }
            for (key, value) in retained { XCTAssertEqual(defaults.string(forKey: key), value) }
            XCTAssertEqual(defaults.object(forKey: "OneDay.scrubberSectionMarks") as? Bool, false)
            XCTAssertEqual(defaults.object(forKey: "OneDay.scrubberTickHaptics") as? Bool, false)
            XCTAssertEqual(defaults.object(forKey: "OneDay.photoCaptions") as? Bool, true)
        }
    }
}
