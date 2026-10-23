import XCTest
@testable import MediaFilter

final class WaterfallLayoutPolicyTests: XCTestCase {
    private func plan(
        _ heights: [CGFloat], columns: Int = 2, width: CGFloat = 100,
        horizontal: CGFloat = 12, vertical: CGFloat = 8
    ) -> WaterfallLayoutPolicy.Plan {
        WaterfallLayoutPolicy.plan(
            heights: heights, columnCount: columns, columnWidth: width,
            horizontalSpacing: horizontal, verticalSpacing: vertical
        )
    }

    func testDefaultAndRemovedLayoutValuesKeepAlignedGrid() {
        for value in [nil, "", "invalid", "magazine", "alignedGrid"] as [String?] {
            XCTAssertEqual(DayGridArrangement(savedValue: value), .aligned)
        }
        XCTAssertEqual(DayGridArrangement.allCases, [.aligned, .waterfall])
    }

    func testArrangementSurvivesAppearanceMigrationWithoutChangingOtherSettings() {
        let name = "WaterfallLayoutPolicyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(4, forKey: GridColumnPolicy.countKey)
        defaults.set("manual", forKey: GridColumnPolicy.modeKey)
        defaults.set(false, forKey: "OneDay.gridLazyEnabled")
        defaults.set(true, forKey: "OneDay.photoCaptions")
        for arrangement in DayGridArrangement.allCases {
            defaults.set(arrangement.rawValue, forKey: DayGridArrangement.storageKey)
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            XCTAssertEqual(
                DayGridArrangement(savedValue: defaults.string(forKey: DayGridArrangement.storageKey)),
                arrangement
            )
            XCTAssertEqual(GridColumnPolicy(itemCount: 100, defaults: defaults).columnCount, 4)
            XCTAssertFalse(defaults.bool(forKey: "OneDay.gridLazyEnabled"))
            XCTAssertTrue(defaults.bool(forKey: "OneDay.photoCaptions"))
        }
    }

    func testEmptyLayoutHasNoPhantomHeight() {
        XCTAssertEqual(plan([]).frames, [])
        XCTAssertEqual(plan([]).size, CGSize(width: 212, height: 0))
    }

    func testEachPhotoGoesToTheShortestColumnWithoutReorderingInput() {
        let result = plan([200, 80, 60, 100])
        XCTAssertEqual(result.frames, [
            CGRect(x: 0, y: 0, width: 100, height: 200),
            CGRect(x: 112, y: 0, width: 100, height: 80),
            CGRect(x: 112, y: 88, width: 100, height: 60),
            CGRect(x: 112, y: 156, width: 100, height: 100)
        ])
        XCTAssertEqual(result.size.height, 256)
    }

    func testEqualColumnsUseDeterministicLeftToRightTies() {
        let result = plan(Array(repeating: 100, count: 6), columns: 3)
        XCTAssertEqual(result.frames.map(\.minX), [0, 112, 224, 0, 112, 224])
        XCTAssertEqual(result.frames.map(\.minY), [0, 0, 0, 108, 108, 108])
        XCTAssertEqual(result, plan(Array(repeating: 100, count: 6), columns: 3))
    }

    func testOneColumnMatchesVerticalStackAndHasNoTrailingGap() {
        let result = plan([100, 40, 60], columns: 1, vertical: 10)
        XCTAssertEqual(result.frames.map(\.minX), [0, 0, 0])
        XCTAssertEqual(result.frames.map(\.minY), [0, 110, 160])
        XCTAssertEqual(result.size, CGSize(width: 100, height: 220))
    }

    func testOneThroughSixColumnsNeverOverlapAndReportExactHeight() {
        let heights = (0..<700).map { CGFloat(20 + ($0 * 71) % 400) }
        for columns in 1...6 {
            let result = plan(heights, columns: columns)
            XCTAssertEqual(result.frames.count, heights.count)
            XCTAssertEqual(result.size.height, result.frames.map(\.maxY).max())
            for column in 0..<columns {
                let x = CGFloat(column) * 112
                let frames = result.frames.filter { $0.minX == x }
                for pair in zip(frames, frames.dropFirst()) {
                    XCTAssertEqual(pair.1.minY - pair.0.maxY, 8)
                }
            }
        }
    }

    func testCaptionHeightParticipatesInColumnAssignment() {
        let withoutCaption = plan([100, 110, 50])
        let withCaption = plan([140, 110, 50])
        XCTAssertEqual(withoutCaption.frames[2].minX, 0)
        XCTAssertEqual(withCaption.frames[2].minX, 112)
        XCTAssertEqual(withCaption.frames[2].minY, 118)
    }

    func testASeparateSectionStartsAtZeroInsteadOfFillingThePreviousSection() {
        _ = plan([600, 80, 40])
        let next = plan([50, 90])
        XCTAssertEqual(next.frames.map(\.minY), [0, 0])
    }

    func testInvalidDimensionsAreFiniteAndColumnsAreClamped() {
        let result = plan(
            [.nan, -.infinity, -10, 50], columns: 0,
            width: .infinity, horizontal: -20, vertical: .nan
        )
        XCTAssertEqual(result.size, CGSize(width: 0, height: 50))
        XCTAssertTrue(result.frames.allSatisfy { $0.minY.isFinite && $0.height >= 0 })
        XCTAssertEqual(plan([10], columns: 99).size.width, 660)
        let zeros = plan([0, 0, 0], columns: 3, vertical: 0)
        XCTAssertEqual(zeros.frames.map(\.minX), [0, 112, 224])
    }

    func testImageLoadingPrefetchesOnlyOneScreenOnEachSide() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        for y: CGFloat in [-450, 100, 700, 1_200] {
            XCTAssertTrue(WaterfallLayoutPolicy.shouldLoadImage(
                frame: CGRect(x: 0, y: y, width: 100, height: 100), viewport: viewport
            ))
        }
        for y: CGFloat in [-700, 1_400, 5_000] {
            XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(
                frame: CGRect(x: 0, y: y, width: 100, height: 100), viewport: viewport
            ))
        }
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(frame: .zero, viewport: viewport))
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(frame: viewport, viewport: .zero))
    }

    func testAnchorPrefersVisibleTopAndUsesLeftmostTie() {
        let viewport = CGRect(x: 0, y: 80, width: 400, height: 600)
        let frames = [
            "partial": CGRect(x: 0, y: 0, width: 100, height: 100),
            "right": CGRect(x: 112, y: 120, width: 100, height: 100),
            "left": CGRect(x: 0, y: 120, width: 100, height: 100),
            "outside": CGRect(x: 0, y: 900, width: 100, height: 100)
        ]
        XCTAssertEqual(
            WaterfallLayoutPolicy.anchor(frames: frames, viewport: viewport),
            .init(id: "left", minY: 120)
        )
        XCTAssertNil(WaterfallLayoutPolicy.anchor(frames: [:], viewport: viewport))
    }

    func testAnchorFallsBackToTallPartiallyVisiblePhoto() {
        let frames = ["tall": CGRect(x: 0, y: -200, width: 100, height: 1_000)]
        XCTAssertEqual(
            WaterfallLayoutPolicy.anchor(
                frames: frames, viewport: CGRect(x: 0, y: 80, width: 400, height: 600)
            ),
            .init(id: "tall", minY: -200)
        )
    }

    func testRestoredOffsetKeepsAnchorAtItsPreviousScreenPosition() {
        let anchor = WaterfallLayoutPolicy.Anchor(id: "photo", minY: 160)
        for shift: CGFloat in [-300, 0, 500] {
            let frames = ["photo": CGRect(x: 112, y: 160 + shift, width: 100, height: 180)]
            let target = WaterfallLayoutPolicy.restoredOffset(
                anchor: anchor, frames: frames, currentOffset: 1_000
            )!
            XCTAssertEqual(target, 1_000 + shift)
            XCTAssertEqual(frames["photo"]!.minY - (target - 1_000), anchor.minY)
        }
        XCTAssertNil(WaterfallLayoutPolicy.restoredOffset(anchor: anchor, frames: [:], currentOffset: 0))
    }

    func testViewportChangesDoNotChangePlacementOrIDs() {
        let heights: [CGFloat] = [90, 250, 80, 140, 700]
        let original = plan(heights)
        for offset: CGFloat in [0, 300, 1_500] {
            let viewport = CGRect(x: 0, y: offset, width: 400, height: 600)
            _ = original.frames.map { WaterfallLayoutPolicy.shouldLoadImage(frame: $0, viewport: viewport) }
            XCTAssertEqual(plan(heights), original)
        }
    }
}
