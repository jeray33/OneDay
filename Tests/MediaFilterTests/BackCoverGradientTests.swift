import XCTest
@testable import MediaFilter

final class BackCoverGradientTests: XCTestCase {
    func testImmersiveGradientKeepsPhotoHueAndDarkensDownward() {
        let stops = BackCoverGradient.stops(hue: 0.6, saturation: 0.9)
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
            let stops = BackCoverGradient.stops(hue: hue, saturation: 0.5)
            XCTAssertTrue(stops.allSatisfy { $0.saturation == 0 })
            XCTAssertLessThan(stops.last!.brightness, stops.first!.brightness)
        }
        XCTAssertTrue(BackCoverGradient.stops(hue: 1.25, saturation: .nan)
            .allSatisfy { $0.hue == 0.25 && $0.saturation > 0 })
    }

    func testMutedPhotoKeepsImmersiveTintWithoutLiftingBrightness() {
        let stops = BackCoverGradient.stops(hue: -0.25, saturation: 0)
        XCTAssertTrue(stops.allSatisfy { $0.hue == 0.75 })
        XCTAssertEqual(stops.first?.saturation, 0.35)
        XCTAssertEqual(stops.map(\.brightness), [0.32, 0.15, 0.05])
    }

    func testDifferentPhotoHuesProduceDifferentGradientsWithSameDarkness() {
        let warm = BackCoverGradient.stops(hue: 0.05, saturation: 0.5)
        let cool = BackCoverGradient.stops(hue: 0.6, saturation: 0.5)
        XCTAssertNotEqual(warm, cool)
        XCTAssertEqual(warm.map(\.brightness), cool.map(\.brightness))
        XCTAssertEqual(warm.map(\.location), cool.map(\.location))
    }
}
