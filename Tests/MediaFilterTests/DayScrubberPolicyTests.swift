import XCTest
@testable import MediaFilter

final class DayScrubberPolicyTests: XCTestCase {

    // MARK: - Metrics

    func testProgressClampsAtBothEnds() {
        let metrics = DayScrubberMetrics(offset: 10, scrolledDistance: -50, scrollableDistance: 400)
        XCTAssertEqual(metrics.progress, 0)
        XCTAssertEqual(metrics.progress(forScrolledDistance: 500), 1)
        XCTAssertEqual(metrics.progress(forScrolledDistance: 200), 0.5, accuracy: 1e-9)
    }

    func testZeroRangeMeansNoProgressAndNoScroll() {
        let metrics = DayScrubberMetrics(offset: 5, scrolledDistance: 0, scrollableDistance: 0)
        XCTAssertFalse(metrics.isScrollable)
        XCTAssertEqual(metrics.progress, 0)
        XCTAssertEqual(metrics.scrolledDistance(forProgress: 1), 0)
        XCTAssertEqual(metrics.targetOffset(forProgress: 1), 5)
    }

    func testTinyRangeIsNotScrollable() {
        XCTAssertFalse(DayScrubberMetrics(offset: 0, scrolledDistance: 0,
                                           scrollableDistance: 16).isScrollable)
        XCTAssertTrue(DayScrubberMetrics(offset: 0, scrolledDistance: 0,
                                          scrollableDistance: 16.5).isScrollable)
    }

    func testNegativeScrollableDistanceIsClampedToZero() {
        let metrics = DayScrubberMetrics(offset: 0, scrolledDistance: 0, scrollableDistance: -30)
        XCTAssertEqual(metrics.scrollableDistance, 0)
        XCTAssertFalse(metrics.isScrollable)
    }

    func testTargetOffsetUsesDifferencesOnly() {
        // Mid-scroll: observed offset 123, halfway scrolled of 400.
        let metrics = DayScrubberMetrics(offset: 123, scrolledDistance: 200, scrollableDistance: 400)
        XCTAssertEqual(metrics.targetOffset(forProgress: 0.5), 123, accuracy: 1e-9)
        XCTAssertEqual(metrics.targetOffset(forProgress: 0), -77, accuracy: 1e-9)
        XCTAssertEqual(metrics.targetOffset(forProgress: 1), 323, accuracy: 1e-9)
    }

    // MARK: - Touch mapping

    func testLocationMappingClampsAndScales() {
        XCTAssertEqual(DayScrubberPolicy.progress(forLocationX: -5, width: 200, inset: 18), 0)
        XCTAssertEqual(DayScrubberPolicy.progress(forLocationX: 205, width: 200, inset: 18), 1)
        // Centre of the usable band (18…182) maps to 0.5.
        XCTAssertEqual(DayScrubberPolicy.progress(forLocationX: 100, width: 200, inset: 18),
                       0.5, accuracy: 1e-9)
    }

    func testLocationMappingWithDegenerateWidth() {
        XCTAssertEqual(DayScrubberPolicy.progress(forLocationX: 10, width: 30, inset: 18), 0)
    }

    // MARK: - Section marks

    func testMarkFractionsSortDropAndClamp() {
        // 40 sits too close to the top, 1200 lies beyond the reachable range.
        let fractions = DayScrubberPolicy.markFractions(
            sectionDistances: [700, 40, 1200, 300],
            scrollableDistance: 1000
        )
        XCTAssertEqual(fractions, [0.3, 0.7])
    }

    func testMarkFractionsMergeCloseNeighbours() {
        let fractions = DayScrubberPolicy.markFractions(
            sectionDistances: [500, 530, 620],
            scrollableDistance: 1000
        )
        XCTAssertEqual(fractions, [0.5, 0.62])
    }

    func testMarkFractionsEmptyWhenUnscrollable() {
        XCTAssertTrue(DayScrubberPolicy
            .markFractions(sectionDistances: [100], scrollableDistance: 0)
            .isEmpty)
    }

    // MARK: - Snapped marks

    func testSnappedMarksLandOnNearestInteriorTick() {
        // 11 ticks → ticks every 0.1; ends (0 and 10) are never used.
        let marks = DayScrubberPolicy.snappedMarks(fractions: [0.62, 0.01, 0.98, 0.34],
                                                   tickCount: 11)
        XCTAssertEqual(marks.map(\.tick), [1, 3, 6, 9])
        XCTAssertEqual(marks.map(\.fraction), [0.01, 0.34, 0.62, 0.98])
    }

    func testSnappedMarksKeepFirstOnSharedTick() {
        let marks = DayScrubberPolicy.snappedMarks(fractions: [0.51, 0.49], tickCount: 11)
        XCTAssertEqual(marks, [DayScrubberMark(tick: 5, fraction: 0.49)])
    }

    func testSnappedMarksNeedInteriorTicks() {
        XCTAssertTrue(DayScrubberPolicy.snappedMarks(fractions: [0.5], tickCount: 2).isEmpty)
    }

    // MARK: - Detent

    func testDetentCatchesNearestMarkWithinEnterRadius() {
        let xs: [CGFloat] = [100, 112]
        XCTAssertNil(DayScrubberPolicy.detentIndex(locationX: 85, markXs: xs, current: nil,
                                                   enterRadius: 9, exitRadius: 14))
        XCTAssertEqual(DayScrubberPolicy.detentIndex(locationX: 93, markXs: xs, current: nil,
                                                     enterRadius: 9, exitRadius: 14), 0)
        XCTAssertEqual(DayScrubberPolicy.detentIndex(locationX: 107, markXs: xs, current: nil,
                                                     enterRadius: 9, exitRadius: 14), 1)
    }

    func testDetentHoldsUntilExitRadius() {
        let xs: [CGFloat] = [100]
        XCTAssertEqual(DayScrubberPolicy.detentIndex(locationX: 113, markXs: xs, current: 0,
                                                     enterRadius: 9, exitRadius: 14), 0)
        XCTAssertNil(DayScrubberPolicy.detentIndex(locationX: 115, markXs: xs, current: 0,
                                                   enterRadius: 9, exitRadius: 14))
    }

    // MARK: - Crossings

    func testCrossingsCountInteriorTicks() {
        // 11 ticks → 10 segments; 0 → 0.3 strictly crosses the 0.1 and 0.2 ticks.
        let crossings = DayScrubberPolicy.crossings(from: 0, to: 0.3, tickCount: 11, marks: [])
        XCTAssertEqual(crossings.tickCrossings, 2)
        XCTAssertFalse(crossings.crossesSectionMark)
    }

    func testCrossingsAreDirectionAgnostic() {
        XCTAssertEqual(
            DayScrubberPolicy.crossings(from: 0.3, to: 0, tickCount: 11, marks: []).tickCrossings,
            2
        )
    }

    func testCrossingsDetectSectionMarks() {
        let crossings = DayScrubberPolicy.crossings(from: 0.2, to: 0.5, tickCount: 3, marks: [0.35])
        XCTAssertTrue(crossings.crossesSectionMark)
        XCTAssertEqual(crossings.tickCrossings, 0)
    }

    func testNoCrossingsWithoutMovement() {
        let crossings = DayScrubberPolicy.crossings(from: 0.4, to: 0.4, tickCount: 11, marks: [0.4])
        XCTAssertEqual(crossings.tickCrossings, 0)
        XCTAssertFalse(crossings.crossesSectionMark)
    }

    func testLandingExactlyOnATickDoesNotCrossIt() {
        // Moving up TO the 0.2 tick (not past it) crosses only the 0.1 tick.
        let crossings = DayScrubberPolicy.crossings(from: 0.05, to: 0.2, tickCount: 11, marks: [])
        XCTAssertEqual(crossings.tickCrossings, 1)
    }
}
