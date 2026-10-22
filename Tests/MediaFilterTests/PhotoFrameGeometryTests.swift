import XCTest
@testable import MediaFilter

final class PhotoFrameGeometryTests: XCTestCase {
    func testScreenshotFillsRoundedViewportInsteadOfLeavingSquareEdgesInsideIt() {
        let image = CGSize(width: 1170, height: 2532)
        let viewport = CGSize(width: 100, height: 160)
        let fill = PhotoFrameGeometry.fillSize(image: image, viewport: viewport)
        XCTAssertEqual(fill.width, viewport.width, accuracy: 0.000001)
        XCTAssertGreaterThan(fill.height, viewport.height)
        XCTAssertEqual(fill.width / fill.height, image.width / image.height, accuracy: 0.000001)
    }

    func testEveryMediaAspectFillsEveryTransitionViewportAndBorderStyle() {
        // Still/Live photos, screenshots, stitched long images, panoramas and
        // portrait/landscape video posters all share this renderer.
        let aspects: [String: CGFloat] = [
            "portrait photo": 3.0 / 4, "landscape photo": 4.0 / 3,
            "square photo": 1, "Live Photo": 3.0 / 2,
            "screenshot": 9.0 / 19.5, "stitched screenshot": 0.02,
            "panorama": 12, "portrait video": 9.0 / 16,
            "landscape video": 16.0 / 9
        ]
        let sizes = [CGSize(width: 120, height: 180), CGSize(width: 240, height: 400),
                     CGSize(width: 360, height: 720)]
        let borders: [(CGFloat, CGFloat)] = [(0, 0), (8, 8), (12, 58)]
        for (name, aspect) in aspects {
            let image = CGSize(width: 1000 * aspect, height: 1000)
            for card in sizes {
                for (border, bottom) in borders {
                    let viewport = PhotoFrameGeometry.imageSize(card: card, border: border, bottomBorder: bottom)
                    let fill = PhotoFrameGeometry.fillSize(image: image, viewport: viewport)
                    XCTAssertGreaterThanOrEqual(fill.width + 0.000001, viewport.width, name)
                    XCTAssertGreaterThanOrEqual(fill.height + 0.000001, viewport.height, name)
                    XCTAssertEqual(fill.width / fill.height, aspect, accuracy: 0.000001, name)
                }
            }
        }
    }

    func testPolaroidStripIsNotCountedAsImageArea() {
        XCTAssertEqual(PhotoFrameGeometry.imageSize(
            card: CGSize(width: 360, height: 700), border: 12, bottomBorder: 58
        ), CGSize(width: 336, height: 630))
    }

    func testBorderlessMediaUsesEntireCard() {
        let card = CGSize(width: 360, height: 700)
        XCTAssertEqual(PhotoFrameGeometry.imageSize(card: card, border: 0, bottomBorder: 0), card)
    }

    func testExtremelyLongScreenshotsKeepTheirRealPreviewAspect() {
        XCTAssertEqual(PhotoFrameGeometry.validAspectRatio(0.02), 0.02)
        XCTAssertEqual(PhotoFrameGeometry.validAspectRatio(12), 12)
        XCTAssertEqual(PhotoFrameGeometry.validAspectRatio(0), 1)
        XCTAssertEqual(PhotoFrameGeometry.validAspectRatio(.nan), 1)
    }

    func testMissingImageOrCollapsedViewportIsSafe() {
        XCTAssertEqual(PhotoFrameGeometry.fillSize(image: .zero, viewport: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(PhotoFrameGeometry.fillSize(image: CGSize(width: 100, height: 100), viewport: .zero), .zero)
        XCTAssertEqual(PhotoFrameGeometry.imageSize(card: .zero, border: 12, bottomBorder: 58), .zero)
    }
}
