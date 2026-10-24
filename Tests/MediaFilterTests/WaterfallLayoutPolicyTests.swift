import XCTest
@testable import MediaFilter

final class WaterfallLayoutPolicyTests: XCTestCase {
    func testVirtualized480ItemDayOnlySelectsNearbyCells() {
        let heights = (0..<480).map { CGFloat(90 + ($0 * 73) % 280) }
        let result = plan(heights, columns: 3)
        let index = WaterfallLayoutPolicy.VisibilityIndex(frames: result.frames)
        for y: CGFloat in [0, 8_000, 20_000, result.size.height - 600] {
            let viewport = CGRect(x: 0, y: y, width: result.size.width, height: 600)
            let window = WaterfallLayoutPolicy.renderWindow(for: viewport)
            let visible = index.indices(in: window)
            XCTAssertLessThan(visible.count, 60)
            XCTAssertEqual(visible, result.frames.indices.filter { result.frames[$0].intersects(window) })
            XCTAssertEqual(result.size.height, result.frames.map(\.maxY).max())
        }
    }

    func testVisibilityIndexMatchesFullScanAcrossAllColumnCounts() {
        for columns in 1...6 {
            let result = plan((0..<480).map { CGFloat(40 + ($0 * 31) % 500) }, columns: columns)
            let index = WaterfallLayoutPolicy.VisibilityIndex(frames: result.frames)
            for y in stride(from: CGFloat(-600), through: result.size.height + 600, by: 271) {
                let viewport = CGRect(x: 0, y: y, width: result.size.width, height: 700)
                XCTAssertEqual(index.indices(in: viewport),
                               result.frames.indices.filter { result.frames[$0].intersects(viewport) })
            }
        }
    }

    func testPinnedPreviewCellSurvivesOutsideTheWindow() {
        let result = plan(Array(repeating: 100, count: 480))
        let index = WaterfallLayoutPolicy.VisibilityIndex(frames: result.frames)
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
        let visible = index.indices(in: viewport, pinned: [479, -1, 999])
        XCTAssertTrue(visible.contains(479))
        XCTAssertFalse(visible.contains(-1))
        XCTAssertFalse(visible.contains(999))
        XCTAssertEqual(visible, visible.sorted())
    }

    func testQuantizedWindowCoversViewportAndSmallScrollsReuseIt() {
        let viewport = CGRect(x: 0, y: 610, width: 400, height: 600)
        let window = WaterfallLayoutPolicy.renderWindow(for: viewport)
        XCTAssertTrue(window.contains(viewport))
        XCTAssertEqual(window, WaterfallLayoutPolicy.renderWindow(for: viewport.offsetBy(dx: 0, dy: 100)))
        XCTAssertNotEqual(window, WaterfallLayoutPolicy.renderWindow(for: viewport.offsetBy(dx: 0, dy: 310)))
        XCTAssertEqual(WaterfallLayoutPolicy.renderWindow(for: .zero), .zero)
    }

    func testPhotoMetricsKeepPosterGeometryIndependentOfCaptionAndLoading() {
        let plain = WaterfallLayoutPolicy.photoMetrics(width: 160, aspectRatio: 1.5, border: 5, captionHeight: nil)
        let caption = WaterfallLayoutPolicy.photoMetrics(width: 160, aspectRatio: 1.5, border: 5, captionHeight: 28)
        XCTAssertEqual(plain.cardHeight, 110)
        XCTAssertEqual(caption.cardHeight, plain.cardHeight)
        XCTAssertEqual(caption.height, 144)
        XCTAssertEqual(WaterfallLayoutPolicy.photoMetrics(
            width: 160, aspectRatio: .nan, border: 5, captionHeight: nil).height, 160)
    }

    func testWindowHysteresisAvoidsCellChurnAndStillCoversFastJumps() {
        var retained = CGRect.zero
        var changes = 0
        for y: CGFloat in [599, 601, 599, 601, 590, 610, 1_300, 30_000, 0] {
            let viewport = CGRect(x: 0, y: y, width: 400, height: 600)
            let next = WaterfallLayoutPolicy.renderWindow(for: viewport)
            if WaterfallLayoutPolicy.shouldReplaceRenderWindow(retained, with: next) {
                retained = next
                changes += 1
            }
            XCTAssertTrue(retained.contains(viewport.insetBy(dx: 0, dy: -290)))
        }
        XCTAssertEqual(changes, 4)
        XCTAssertTrue(WaterfallLayoutPolicy.shouldReplaceRenderWindow(
            retained, with: CGRect(x: 0, y: 0, width: 800, height: 2_100)))
    }

    func testMixedCardsCaptionsAndOneColumnKeepOffscreenPositionsAvailable() {
        let heights: [CGFloat] = [240, 100, 134, 320, 600, 140]
        for columns in 1...6 {
            let result = plan(heights, columns: columns)
            let index = WaterfallLayoutPolicy.VisibilityIndex(frames: result.frames)
            let viewport = CGRect(x: 0, y: result.frames[4].minY, width: result.size.width, height: 200)
            XCTAssertTrue(index.indices(in: viewport).contains(4))
            XCTAssertEqual(result.frames.count, heights.count)
            XCTAssertEqual(result.frames.map(\.height), heights)
        }
    }

    func testOffscreenCenterAndTopTargetsDoNotNeedInstantiatedCells() {
        let viewport = CGRect(x: 0, y: 1_080, width: 400, height: 600)
        let target = CGRect(x: 112, y: 20_000, width: 100, height: 200)
        XCTAssertEqual(DayContentCoordinates.targetOffset(
            for: target, viewport: viewport, currentOffset: 1_000, anchor: 0.5), 19_720)
        XCTAssertEqual(DayContentCoordinates.targetOffset(
            for: target, viewport: viewport, currentOffset: 1_000, anchor: 0), 19_920)
        XCTAssertNil(DayContentCoordinates.targetOffset(
            for: .zero, viewport: viewport, currentOffset: 1_000, anchor: 0.5))
    }

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

    func testImageLoadingKeepsLoadedCellsLongEnoughToAvoidOscillation() {
        let viewport = CGRect(x: 0, y: 100, width: 400, height: 600)
        // Within one screen of the viewport: loads either way.
        let near = CGRect(x: 0, y: 1_200, width: 100, height: 100)
        XCTAssertTrue(WaterfallLayoutPolicy.shouldLoadImage(
            frame: near, viewport: viewport, isLoaded: false
        ))
        XCTAssertTrue(WaterfallLayoutPolicy.shouldLoadImage(
            frame: near, viewport: viewport, isLoaded: true
        ))
        // Past one screen but within 2.5 screens: only an already-loaded cell
        // keeps its image, so a boundary cell cannot flip on and off.
        let mid = CGRect(x: 0, y: 1_800, width: 100, height: 100)
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(
            frame: mid, viewport: viewport, isLoaded: false
        ))
        XCTAssertTrue(WaterfallLayoutPolicy.shouldLoadImage(
            frame: mid, viewport: viewport, isLoaded: true
        ))
        // Past 2.5 screens even a loaded cell releases its image.
        let far = CGRect(x: 0, y: 2_300, width: 100, height: 100)
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(
            frame: far, viewport: viewport, isLoaded: true
        ))
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(
            frame: far, viewport: viewport, isLoaded: false
        ))
        XCTAssertFalse(WaterfallLayoutPolicy.shouldLoadImage(
            frame: .zero, viewport: viewport, isLoaded: true
        ))
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
