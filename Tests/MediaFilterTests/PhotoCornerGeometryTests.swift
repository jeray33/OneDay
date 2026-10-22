import XCTest
@testable import MediaFilter

final class PhotoCornerGeometryTests: XCTestCase {
    func testPreviewRadiusGrowsInProportionToDayCardWidth() {
        let geometry = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 8)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 120, height: 160)), 8)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 360, height: 480)), 24)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 60, height: 80)), 4)
    }

    func testIntermediateTransitionSizesKeepTheSameRelativeRadius() {
        let geometry = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 8)
        for width in [CGFloat(120), 180, 240, 300, 360] {
            XCTAssertEqual(geometry.radius(for: CGSize(width: width, height: width * 2)) / width,
                           8.0 / 120, accuracy: 0.000001)
        }
    }

    func testDragScaleAndReverseTransitionMatchPreviewCurvature() {
        let geometry = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 8)
        let preview = CGSize(width: 360, height: 480)
        let scale: CGFloat = 0.7
        XCTAssertEqual(geometry.radius(for: CGSize(width: preview.width * scale, height: preview.height * scale)),
                       geometry.radius(for: preview) * scale, accuracy: 0.000001)
    }

    func testNoRadiusRemainsSquareAtEverySize() {
        let geometry = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 0)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 360, height: 480)), 0)
    }

    func testPanoramaRadiusCannotExceedHalfTheShortSide() {
        let geometry = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 24)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 360, height: 40)), 20)
    }

    func testInvalidDimensionsDoNotProduceInvalidLayerRadii() {
        let geometry = PhotoCornerGeometry(referenceWidth: 0, cornerRadius: 8)
        XCTAssertEqual(geometry.radius(for: CGSize(width: 360, height: 480)), 0)
        let valid = PhotoCornerGeometry(referenceWidth: 120, cornerRadius: 8)
        XCTAssertEqual(valid.radius(for: .zero), 0)
        XCTAssertEqual(valid.radius(for: CGSize(width: CGFloat.infinity, height: 480)), 0)
    }
}
