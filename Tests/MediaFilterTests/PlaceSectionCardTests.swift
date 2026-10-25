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

    func testStyleRestoresSavedSelectionWithoutChangingExistingDefault() {
        XCTAssertEqual(PlaceCardStyle(savedValue: nil), .solid)
        XCTAssertEqual(PlaceCardStyle(savedValue: "unknown"), .solid)
        for style in PlaceCardStyle.allCases {
            XCTAssertEqual(PlaceCardStyle(savedValue: style.rawValue), style)
        }
    }

    func testDiffuseGradientIsStableAcrossNameResolutionAndTimeChanges() {
        XCTAssertEqual(card().diffuseGradient, card(name: "西湖", time: "10:00").diffuseGradient)
        XCTAssertEqual(card().diffuseGradient, card().diffuseGradient)
        XCTAssertNotEqual(card("other-stop").diffuseGradient, card().diffuseGradient)
    }

    func testDiffuseGradientUsesOneHueWithoutWashingOutToWhite() {
        for index in 0..<100 {
            let card = card("stop-\(index)")
            let base = [card.color.red, card.color.green, card.color.blue]
            for color in card.diffuseGradient.colors {
                let components = [color.red, color.green, color.blue]
                // Constant distance ratios from white mean no new hue.
                let strengths = zip(components, base).map { (1 - $0.0) / (1 - $0.1) }
                XCTAssertEqual(strengths[0], strengths[1], accuracy: 0.0001)
                XCTAssertEqual(strengths[1], strengths[2], accuracy: 0.0001)
                XCTAssertGreaterThanOrEqual(strengths[0], 0.65)
                XCTAssertTrue(components.allSatisfy { (0.44...1).contains($0) })
            }
        }
    }

    func testDiffuseGradientHasOneSaturatedCoreThatVariesBetweenCards() {
        let gradients = (0..<100).map { card("random-\($0)").diffuseGradient }
        for gradient in gradients {
            XCTAssertEqual(gradient.blobs.count, 2)
            let base = gradient.base, core = gradient.blobs[1].color
            XCTAssertLessThan(core.red + core.green + core.blue, base.red + base.green + base.blue)
            for blob in gradient.blobs {
                XCTAssertTrue((0.4...0.6).contains(blob.x))
                XCTAssertTrue((0.4...0.6).contains(blob.y))
                XCTAssertGreaterThanOrEqual(min(blob.width, blob.height), 0.4)
            }
        }
        XCTAssertGreaterThan(Set(gradients.map { $0.base.red }).count, 90)
        XCTAssertGreaterThan(Set(gradients.map { $0.blobs[0].x }).count, 90)
    }

    func testEdgeGlowUsesBrighterTonesOfTheCardHueInTheCenter() {
        for index in 0..<100 {
            let card = card("edge-\(index)")
            let glow = card.edgeGlow
            for tone in [glow.centerTop, glow.centerBottom, glow.edge] {
                let strengths = zip([tone.red, tone.green, tone.blue],
                                    [card.color.red, card.color.green, card.color.blue])
                    .map { (1 - $0.0) / (1 - $0.1) }
                XCTAssertEqual(strengths[0], strengths[1], accuracy: 0.0001)
                XCTAssertEqual(strengths[1], strengths[2], accuracy: 0.0001)
            }
            let sum = { (p: PlaceSectionCard.Pastel) in p.red + p.green + p.blue }
            XCTAssertGreaterThan(sum(glow.centerTop), sum(glow.centerBottom))
            XCTAssertGreaterThan(sum(glow.centerBottom), sum(glow.edge))
            XCTAssertTrue([glow.edge.red, glow.edge.green, glow.edge.blue].allSatisfy { $0 >= 0.4399 })
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
