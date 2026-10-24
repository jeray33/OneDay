import Foundation
import MapKit
import XCTest
@testable import MediaFilter

final class RouteMapStyleTests: XCTestCase {
    func testOnlyNativeMutedAndStandardStylesAreSelectable() {
        XCTAssertEqual(RouteMapStyle.allCases, [.muted, .standard])
        XCTAssertEqual(RouteMapStyle.allCases.map(\.label), ["淡彩", "标准"])
    }

    func testDefaultPreservesFormerDefaultMapAppearance() {
        for value in [nil, "", "unknown", "normal", "multiply", "overlay", "softLight", "colorBurnDodge"] {
            XCTAssertEqual(RouteMapStyle(savedValue: value), .muted)
        }
    }

    func testStylesUseCorrespondingSystemMapTypes() {
        XCTAssertEqual(RouteMapStyle.muted.mapType, .mutedStandard)
        XCTAssertEqual(RouteMapStyle.standard.mapType, .standard)
    }

    func testRetainedSelectionsRoundTrip() {
        for style in RouteMapStyle.allCases {
            XCTAssertEqual(RouteMapStyle(savedValue: style.rawValue), style)
        }
    }

    func testOldVisibilityAndBlendSettingsAreRemovedWithoutOverridingNewStyle() {
        let suite = "RouteMapStyleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PageBackground.bright.rawValue, forKey: "OneDay.pageBackground")
        defaults.set(BackCoverBackground.paper.rawValue, forKey: BackCoverBackground.storageKey)
        defaults.set(PreviewBackground.immersive.rawValue, forKey: PreviewBackground.storageKey)
        for style in RouteMapStyle.allCases {
            defaults.set(style.rawValue, forKey: RouteMapStyle.storageKey)
            for visible in [false, true] {
                for blend in ["normal", "multiply", "overlay", "softLight", "colorBurnDodge", "invalid"] {
                    defaults.set(visible, forKey: "OneDay.photoMap")
                    defaults.set(blend, forKey: "OneDay.mapBlendMode")
                    DayAppearancePreferences.migrateLegacySettings(in: defaults)
                    DayAppearancePreferences.migrateLegacySettings(in: defaults)
                    XCTAssertNil(defaults.object(forKey: "OneDay.photoMap"))
                    XCTAssertNil(defaults.object(forKey: "OneDay.mapBlendMode"))
                    XCTAssertEqual(RouteMapStyle(savedValue: defaults.string(forKey: RouteMapStyle.storageKey)), style)
                    XCTAssertEqual(defaults.string(forKey: "OneDay.pageBackground"), PageBackground.bright.rawValue)
                    XCTAssertEqual(defaults.string(forKey: BackCoverBackground.storageKey), BackCoverBackground.paper.rawValue)
                    XCTAssertEqual(defaults.string(forKey: PreviewBackground.storageKey), PreviewBackground.immersive.rawValue)
                }
            }
        }
    }
}
