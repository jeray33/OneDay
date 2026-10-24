import XCTest
@testable import MediaFilter

final class BackCoverBackgroundTests: XCTestCase {
    func testSavedValueDefaultsToTinted() {
        XCTAssertEqual(BackCoverBackground(savedValue: nil), .tinted)
        XCTAssertEqual(BackCoverBackground(savedValue: "bogus"), .tinted)
        for option in BackCoverBackground.allCases {
            XCTAssertEqual(BackCoverBackground(savedValue: option.rawValue), option)
        }
    }

    func testNeutralOptionsUseFixedLevelsAndOnlyBlackIsDark() throws {
        XCTAssertEqual(BackCoverBackground.allCases.map(\.label), ["彩色", "白色", "灰色", "黑色", "沉浸"])
        XCTAssertNil(BackCoverBackground.tinted.whiteLevel)
        XCTAssertEqual(BackCoverBackground.white.whiteLevel, 1)
        XCTAssertEqual(BackCoverBackground.black.whiteLevel, 0)
        let gray = try XCTUnwrap(BackCoverBackground.gray.whiteLevel)
        XCTAssertTrue(gray > 0 && gray < 1)
        XCTAssertNil(BackCoverBackground.immersive.whiteLevel)
        XCTAssertEqual(BackCoverBackground.allCases.filter(\.isDark), [.black, .immersive])
    }

    func testImmersiveGradientKeepsPhotoHueAndDarkensDownward() {
        let stops = BackCoverBackground.immersiveStops(hue: 0.6, saturation: 0.9)
        XCTAssertEqual(stops.map(\.location), [0, 0.5, 1])
        XCTAssertTrue(stops.allSatisfy { $0.hue == 0.6 })
        XCTAssertTrue(stops.allSatisfy { $0.brightness <= 0.32 })
        XCTAssertEqual(stops.first?.saturation, 0.6)
        for (upper, lower) in zip(stops, stops.dropFirst()) {
            XCTAssertGreaterThan(upper.brightness, lower.brightness)
        }
    }

    func testImmersiveGradientFallsBackToNeutralWithoutPhotoHue() {
        for hue in [nil, Double.nan] {
            let stops = BackCoverBackground.immersiveStops(hue: hue, saturation: 0.5)
            XCTAssertTrue(stops.allSatisfy { $0.saturation == 0 })
            XCTAssertLessThan(stops.last!.brightness, stops.first!.brightness)
        }
        XCTAssertTrue(BackCoverBackground.immersiveStops(hue: 1.25, saturation: .nan)
            .allSatisfy { $0.hue == 0.25 && $0.saturation > 0 })
    }
}
