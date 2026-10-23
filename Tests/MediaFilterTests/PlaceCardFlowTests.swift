import XCTest
import CoreGraphics
@testable import MediaFilter

final class PlaceCardFlowTests: XCTestCase {
    func testDefaultAndInvalidStoredModesPreserveSeparatedLayout() {
        XCTAssertEqual(PlaceCardFlow(savedValue: nil), .separated)
        XCTAssertEqual(PlaceCardFlow(savedValue: ""), .separated)
        XCTAssertEqual(PlaceCardFlow(savedValue: "unknown"), .separated)
        XCTAssertEqual(PlaceCardFlow.allCases.map(\.label), ["分离", "连续"])
    }

    func testSavedSelectionRestoresBothModes() {
        for flow in PlaceCardFlow.allCases {
            XCTAssertEqual(PlaceCardFlow(savedValue: flow.rawValue), flow)
        }
    }

    func testFlowChoiceOnlyAppliesToEnabledPlaceCardsInWaterfall() {
        for arrangement in DayGridArrangement.allCases {
            for form in TitleSegmentationPolicy.Form.allCases {
                for enabled in [false, true] {
                    XCTAssertEqual(
                        PlaceCardFlow.isApplicable(arrangement: arrangement, placeEnabled: enabled, form: form),
                        arrangement == .waterfall && enabled && form == .card
                    )
                }
            }
        }
    }

    func testContinuousWaterfallUsesRemainingSpaceInsteadOfRestartingColumns() {
        // Each group starts with its place card. The first group has a tall
        // photo; the second card should fill the short column alongside it.
        let first: [CGFloat] = [160, 500]
        let second: [CGFloat] = [160, 100, 220]
        let continuous = plan(first + second, columns: 2)
        let separatedFirst = plan(first, columns: 2)
        let separatedSecond = plan(second, columns: 2)
        let separateStart = separatedFirst.size.height + 32
        XCTAssertEqual(continuous.frames.count, first.count + second.count)
        XCTAssertEqual(continuous.frames[2].minY, 184)
        XCTAssertEqual(continuous.frames[2].minX, 0)
        XCTAssertLessThan(continuous.frames[2].minY, separatedFirst.size.height)
        XCTAssertLessThan(continuous.size.height, separateStart + separatedSecond.size.height)
    }

    func testContinuousFlowRetainsEveryCellAndNeverOverlapsAtAnyColumnCount() {
        let heights: [CGFloat] = [160, 500, 80, 160, 100, 220, 160, 400]
        for columns in 1...6 {
            let continuous = plan(heights, columns: columns)
            XCTAssertEqual(continuous.frames.count, heights.count)
            for (index, frame) in continuous.frames.enumerated() {
                XCTAssertEqual(frame.height, heights[index])
                if index > 0 { XCTAssertGreaterThanOrEqual(frame.minY, continuous.frames[index - 1].minY) }
                for previous in continuous.frames.prefix(index) {
                    XCTAssertFalse(frame.intersects(previous))
                }
            }
        }
    }

    func testSingleColumnContinuousLayoutUsesOnlyOrdinaryPhotoSpacing() {
        let heights: [CGFloat] = [160, 120, 160, 240]
        let continuous = plan(heights, columns: 1)
        XCTAssertEqual(continuous.frames[2].minY, 328)
        XCTAssertEqual(continuous.size.height, heights.reduce(0, +) + 3 * 24)
    }

    private func plan(_ heights: [CGFloat], columns: Int) -> WaterfallLayoutPolicy.Plan {
        WaterfallLayoutPolicy.plan(
            heights: heights, columnCount: columns, columnWidth: 120,
            horizontalSpacing: 12, verticalSpacing: 24
        )
    }
}
