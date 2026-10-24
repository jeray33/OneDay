import XCTest
import CoreGraphics
@testable import MediaFilter

final class PlaceSectionCardTests: XCTestCase {
    private func card(_ stopID: String = "stop", name: String? = nil,
                      time: String = "09:20 – 11:45", avoiding: Int? = nil) -> PlaceSectionCard {
        PlaceSectionCard(stopID: stopID, firstPhotoID: "photo", placeName: name,
                         timeText: time, avoiding: avoiding)
    }

    func testGeocodingChangesNeitherIdentityNorColor() {
        let pending = card()
        let resolved = card(name: "西湖")
        XCTAssertEqual(pending.title, "……")
        XCTAssertTrue(pending.isLoading)
        XCTAssertEqual(resolved.title, "西湖")
        XCTAssertFalse(resolved.isLoading)
        XCTAssertEqual(pending.id, resolved.id)
        XCTAssertEqual(pending.paletteIndex, resolved.paletteIndex)
        XCTAssertEqual(pending.color, resolved.color)
        XCTAssertEqual(pending.firstPhotoID, "photo")
        XCTAssertNotEqual(pending.id, pending.firstPhotoID)
    }

    func testStableHashDoesNotUseRandomizedProcessHashing() {
        XCTAssertEqual(card("").paletteIndex, 5)
        XCTAssertEqual(card("a").paletteIndex, 4)
        XCTAssertEqual(card("b").paletteIndex, 5)
        XCTAssertEqual(card("a").paletteIndex, card("a").paletteIndex)
        XCTAssertNotEqual(card("first-visit", name: "西湖").id,
                          card("return-visit", name: "西湖").id)
    }

    func testNeighborCardsCanAvoidTheSamePastelDeterministically() {
        let first = card()
        let next = card(avoiding: first.paletteIndex)
        XCTAssertNotEqual(first.paletteIndex, next.paletteIndex)
        XCTAssertEqual(next.paletteIndex, card(avoiding: first.paletteIndex).paletteIndex)
        XCTAssertEqual(next.id, first.id)
        for index in 0..<100 {
            let card = card("stop-\(index)")
            XCTAssertTrue(PlaceSectionCard.palette.indices.contains(card.paletteIndex))
        }
    }

    func testTimeAndNameDoNotChangeTheColorSeed() {
        XCTAssertEqual(card(name: "西湖").paletteIndex,
                       card(name: "杭州市西湖区", time: "09:20").paletteIndex)
        XCTAssertEqual(card(name: "地点 1").id, card().id)
        XCTAssertFalse(card(name: "地点 1").isLoading)
    }

    func testPaletteRemainsLightForDarkText() {
        XCTAssertEqual(PlaceSectionCard.palette.count, 8)
        for color in PlaceSectionCard.palette {
            for component in [color.red, color.green, color.blue] {
                XCTAssertTrue((0.75...1).contains(component))
            }
        }
    }

    func testCardsOccupyOnePortraitCellAtEveryColumnCount() {
        for columns in 1...6 {
            let grid = DayPhotoGridSizing(
                viewportWidth: 393, columnCount: columns,
                horizontalSpacing: nil, sideSpacing: .max
            )
            let sizing = PlaceSectionCard.Sizing(width: grid.cellWidth)
            XCTAssertEqual(sizing.width / sizing.height, 0.75, accuracy: 0.0001)
            XCTAssertEqual(sizing.width, grid.cellWidth)
            XCTAssertGreaterThan(sizing.width - sizing.inset * 2, 0)
            XCTAssertGreaterThanOrEqual(sizing.titleFontSize(preferred: 38), 10)
            XCTAssertGreaterThanOrEqual(sizing.timeFontSize, 8)
            let plan = WaterfallLayoutPolicy.plan(
                heights: [sizing.height, 120, 240], columnCount: columns,
                columnWidth: grid.cellWidth, horizontalSpacing: grid.horizontalSpacing,
                verticalSpacing: 24
            )
            XCTAssertEqual(plan.frames.count, 3)
            XCTAssertEqual(plan.frames[0].minX, 0)
            XCTAssertEqual(plan.frames[0].minY, 0)
            XCTAssertEqual(plan.frames[0].height, sizing.height)
        }
    }

    func testNarrowCardsWrapTimeInsteadOfShrinkingItIndefinitely() {
        let narrow = PlaceSectionCard.Sizing(width: 48)
        XCTAssertTrue(narrow.wrapsTime)
        XCTAssertEqual(narrow.titleLineLimit, 2)
        XCTAssertEqual(narrow.titleFontSize(preferred: 38), 10)
        let wide = PlaceSectionCard.Sizing(width: 300)
        XCTAssertFalse(wide.wrapsTime)
        XCTAssertEqual(wide.titleLineLimit, 3)
        XCTAssertEqual(wide.titleFontSize(preferred: 38), 38)
        XCTAssertEqual(wide.inset, 20)
    }

    func testSquareCardsHaveEqualWidthAndHeightAtEveryColumnCount() {
        for columns in 1...6 {
            let grid = DayPhotoGridSizing(
                viewportWidth: 393, columnCount: columns,
                horizontalSpacing: nil, sideSpacing: .max
            )
            let sizing = PlaceSectionCard.Sizing(width: grid.cellWidth, ratio: .square)
            XCTAssertEqual(sizing.width, grid.cellWidth)
            XCTAssertEqual(sizing.height, sizing.width)
        }
    }

    func testRatioRestoresSavedSelectionAndPreservesPortraitDefault() {
        XCTAssertEqual(PlaceCardRatio(savedValue: nil), .portrait)
        XCTAssertEqual(PlaceCardRatio(savedValue: "unknown"), .portrait)
        for ratio in PlaceCardRatio.allCases {
            XCTAssertEqual(PlaceCardRatio(savedValue: ratio.rawValue), ratio)
        }
        XCTAssertEqual(PlaceCardRatio.portrait.label, "3:4")
        XCTAssertEqual(PlaceCardRatio.square.label, "1:1")
    }

    func testInvalidGeometryCannotCreateNaNLayout() {
        for width in [CGFloat.nan, .infinity, -.infinity, -10, 0] {
            let sizing = PlaceSectionCard.Sizing(width: width)
            XCTAssertEqual(sizing.width, 1)
            XCTAssertTrue(sizing.height.isFinite)
            XCTAssertTrue(sizing.titleFontSize(preferred: .nan).isFinite)
        }
    }
}
