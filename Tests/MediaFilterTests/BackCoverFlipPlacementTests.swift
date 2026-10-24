import XCTest
import CoreGraphics
@testable import MediaFilter

final class BackCoverFlipPlacementTests: XCTestCase {
    private let h: CGFloat = 800

    private func place(fromBack: Bool, _ offset: CGFloat) -> BackCoverFlipPlacement {
        .make(fromBack: fromBack, offset: offset, height: h)
    }

    func testPagesStayAttachedInBothDirections() {
        for offset in stride(from: CGFloat(0), through: h, by: 100) {
            let up = place(fromBack: false, -offset)
            XCTAssertEqual(up.backOffset - up.contentOffset, h)
            let down = place(fromBack: true, offset)
            XCTAssertEqual(down.backOffset - down.contentOffset, h)
        }
    }

    func testCommittedEndsMatchDestinationRest() {
        XCTAssertEqual(place(fromBack: false, -h), place(fromBack: true, 0))
        XCTAssertEqual(place(fromBack: true, h), place(fromBack: false, 0))
    }

    func testCancelledFlipReturnsToOriginalRestPlacement() {
        XCTAssertEqual(place(fromBack: false, 0),
                       BackCoverFlipPlacement(contentOffset: 0, backOffset: h))
        XCTAssertEqual(place(fromBack: true, 0),
                       BackCoverFlipPlacement(contentOffset: -h, backOffset: 0))
    }

    func testDayPageClampsAtFullHeight() {
        XCTAssertEqual(place(fromBack: false, -h * 2), place(fromBack: false, -h))
        XCTAssertEqual(place(fromBack: true, h * 2).contentOffset, 0)
    }

    func testInvalidHeightStillProducesFinitePlacement() {
        for height in [CGFloat(0), -1, .nan, .infinity] {
            let up = BackCoverFlipPlacement.make(fromBack: false, offset: -1, height: height)
            XCTAssertEqual(up, BackCoverFlipPlacement(contentOffset: -1, backOffset: 0))
            let down = BackCoverFlipPlacement.make(fromBack: true, offset: 0, height: height)
            XCTAssertEqual(down, BackCoverFlipPlacement(contentOffset: -1, backOffset: 0))
        }
    }
}
