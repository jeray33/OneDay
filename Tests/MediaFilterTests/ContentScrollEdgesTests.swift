import XCTest
@testable import MediaFilter

final class ContentScrollEdgesTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 100, width: 390, height: 744)

    func testLongContentOnlyAllowsCoverAtTop() {
        let edges = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: 100, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertTrue(edges.atTop)
        XCTAssertFalse(edges.atBottom)
    }

    func testScrollingInTheMiddleDoesNotAllowEitherPageFlip() {
        let edges = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: -500, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertFalse(edges.atTop)
        XCTAssertFalse(edges.atBottom)
    }

    func testReachingTheActualBottomAllowsBackCover() {
        let edges = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: -1_156, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertFalse(edges.atTop)
        XCTAssertTrue(edges.atBottom)
    }

    func testShortAndEmptyContentAllowBothDirectionsWithoutScrolling() {
        for height: CGFloat in [0, 200, viewport.height] {
            let edges = ContentScrollEdges(
                contentBounds: CGRect(x: 0, y: viewport.minY, width: 390, height: height),
                viewportBounds: viewport
            )
            XCTAssertTrue(edges.atTop)
            XCTAssertTrue(edges.atBottom)
        }
    }

    func testOverscrollDoesNotLoseTheReachedEdge() {
        let top = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: 164, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertTrue(top.atTop)
        XCTAssertFalse(top.atBottom)
        let bottom = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: -1_220, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertFalse(bottom.atTop)
        XCTAssertTrue(bottom.atBottom)
    }

    func testHeaderHeightDoesNotMoveTheBottomThreshold() {
        for headerHeight: CGFloat in [0, 60, 100, 160] {
            let viewport = CGRect(x: 0, y: headerHeight, width: 390, height: 844 - headerHeight)
            let top = ContentScrollEdges(
                contentBounds: CGRect(x: 0, y: headerHeight, width: 390, height: 2_000),
                viewportBounds: viewport
            )
            let bottom = ContentScrollEdges(
                contentBounds: CGRect(x: 0, y: -1_156, width: 390, height: 2_000),
                viewportBounds: viewport
            )
            XCTAssertTrue(top.atTop)
            XCTAssertFalse(top.atBottom)
            XCTAssertFalse(bottom.atTop)
            XCTAssertTrue(bottom.atBottom)
        }
    }

    func testTabAndContentHeightChangesRecomputeTheBottom() {
        let long = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: 100, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertFalse(long.atBottom)
        let short = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: 100, width: 390, height: 300),
            viewportBounds: viewport
        )
        XCTAssertTrue(short.atBottom)
        let beforeBottom = ContentScrollEdges(
            contentBounds: CGRect(x: 0, y: -1_100, width: 390, height: 2_000),
            viewportBounds: viewport
        )
        XCTAssertFalse(beforeBottom.atBottom)
    }

    func testUnlaidOutViewportDoesNotAllowPaging() {
        XCTAssertEqual(
            ContentScrollEdges(contentBounds: .zero, viewportBounds: .zero),
            ContentScrollEdges(atTop: false, atBottom: false)
        )
    }
}
