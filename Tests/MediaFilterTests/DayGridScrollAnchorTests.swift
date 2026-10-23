import XCTest
@testable import MediaFilter

final class DayGridScrollAnchorTests: XCTestCase {
    private let instanceID = UUID()
    private let sectionID = UUID()
    private let viewport = CGRect(x: 0, y: 80, width: 400, height: 600)

    private func revision(
        arrangement: DayGridArrangement = .waterfall, columns: Int = 2,
        category: String = "photos", instance: UUID? = nil,
        ids: [String] = ["a", "b"], captions: [String?] = [],
        sideSpacing: DayPhotoSideSpacing = .max,
        cardIDs: [String] = [], fallbacks: [String: String] = [:], form: String = "title",
        flow: PlaceCardFlow = .separated
    ) -> DayGridLayoutRevision {
        DayGridLayoutRevision(
            instanceID: instance ?? instanceID, category: category,
            arrangement: arrangement, columns: columns, width: 360,
            sideSpacing: sideSpacing,
            horizontalSpacing: nil, verticalSpacing: 16, border: "max",
            showsCaptions: !captions.isEmpty, captions: captions,
            itemIDs: ids, sections: [sectionID],
            placeCardIDs: cardIDs, cardPhotoFallbacks: fallbacks, segmentationForm: form,
            placeCardFlow: flow
        )
    }

    private func frames(_ a: CGFloat = 120, _ b: CGFloat = 300) -> [String: CGRect] {
        ["a": CGRect(x: 0, y: a, width: 100, height: 160),
         "b": CGRect(x: 112, y: b, width: 100, height: 160)]
    }

    @discardableResult
    private func update(
        _ tracker: DayGridAnchorTracker, _ frames: [String: CGRect],
        _ revision: DayGridLayoutRevision, offset: CGFloat = 1_000, enabled: Bool = true
    ) -> DayGridAnchorTracker.Adjustment? {
        tracker.update(frames: frames, revision: revision, viewport: viewport,
                       offset: offset, enabled: enabled)
    }

    func testInitialMeasurementAndOrdinaryScrollingNeverRestoreAnOldOffset() {
        let tracker = DayGridAnchorTracker()
        XCTAssertNil(update(tracker, frames(), revision()))
        XCTAssertNil(update(tracker, frames(90, 270), revision(), offset: 1_030))
        XCTAssertNil(update(tracker, frames(-100, 80), revision(), offset: 1_220))
    }

    func testSwitchingToWaterfallKeepsTheSamePhotoAtTheSameScreenHeight() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision(arrangement: .aligned))
        XCTAssertEqual(update(tracker, frames(500, 700), revision()), .offset(1_380))
        // Applying the adjustment must not start a correction loop.
        XCTAssertNil(update(tracker, frames(), revision(), offset: 1_380))
    }

    func testColumnAndCaptionChangesRestoreVisibleAnchor() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision())
        XCTAssertEqual(
            update(tracker, frames(200, 500), revision(columns: 3)),
            .offset(1_080)
        )
        XCTAssertEqual(
            update(tracker, frames(250, 600), revision(columns: 3, captions: ["long caption", nil])),
            .offset(1_050)
        )
    }

    func testAlignedOnlyChangesRetainExistingGridBehavior() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision(arrangement: .aligned))
        XCTAssertNil(update(tracker, frames(500, 700), revision(arrangement: .aligned, columns: 3)))
    }

    func testSideSpacingChangePreservesAnchorInBothArrangements() {
        for arrangement in DayGridArrangement.allCases {
            let tracker = DayGridAnchorTracker()
            update(tracker, frames(), revision(arrangement: arrangement))
            XCTAssertEqual(
                update(tracker, frames(200, 500),
                       revision(arrangement: arrangement, sideSpacing: .small)),
                .offset(1_080)
            )
            XCTAssertNil(update(
                tracker, frames(120, 420),
                revision(arrangement: arrangement, sideSpacing: .small), offset: 1_080
            ))
        }
    }

    func testDayAndCategoryChangesDoNotFightTheTopReset() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision())
        XCTAssertNil(update(tracker, frames(500, 700), revision(category: "videos")))
        XCTAssertNil(update(tracker, frames(50, 400), revision(instance: UUID())))
    }

    func testDeletedAnchorUsesTheNextSurvivingVisiblePhoto() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision())
        let remaining = ["b": CGRect(x: 0, y: 150, width: 100, height: 160)]
        XCTAssertEqual(update(tracker, remaining, revision(ids: ["b"])), .offset(850))
        XCTAssertNil(update(tracker, [:], revision(ids: [])))
    }

    func testSwitchingBackToLazyGridRevealsMissingAnchorOnlyOnce() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision())
        let aligned = revision(arrangement: .aligned)
        XCTAssertEqual(update(tracker, [:], aligned), .reveal("a"))
        XCTAssertNil(update(tracker, [:], aligned))
        XCTAssertEqual(update(tracker, frames(80, 260), aligned, offset: 2_000), .offset(1_960))
        XCTAssertNil(update(tracker, frames(), aligned, offset: 1_960))
    }

    func testPreviewOrPageFlipDisablesAndClearsPendingRestoration() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision())
        let aligned = revision(arrangement: .aligned)
        XCTAssertEqual(update(tracker, [:], aligned), .reveal("a"))
        XCTAssertNil(update(tracker, frames(600, 800), aligned, enabled: false))
        XCTAssertNil(update(tracker, frames(), aligned))
    }

    func testSameGeometryWithNewArrangementDoesNotUndoTheNextUserScroll() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision(arrangement: .aligned))
        XCTAssertNil(update(tracker, frames(), revision()))
        XCTAssertNil(update(tracker, frames(90, 270), revision(), offset: 1_030))
    }

    func testAlignedGridRetainsPhotoWhenSwitchingFromTitlesToCards() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(), revision(arrangement: .aligned))
        let withCard = revision(arrangement: .aligned, cardIDs: ["place-card:p"], form: "card")
        XCTAssertEqual(update(tracker, frames(250, 500), withCard), .offset(1_130))
        XCTAssertNil(update(tracker, frames(), withCard, offset: 1_130))
    }

    func testVisiblePlaceCardCanAnchorColumnAndArrangementChanges() {
        for arrangement in DayGridArrangement.allCases {
            let tracker = DayGridAnchorTracker()
            let id = "place-card:p"
            let old = [id: CGRect(x: 0, y: 120, width: 280, height: 380)]
            let new = [id: CGRect(x: 0, y: 200, width: 140, height: 190)]
            update(tracker, old, revision(arrangement: arrangement, columns: 1, cardIDs: [id], form: "card"))
            XCTAssertEqual(
                update(tracker, new, revision(arrangement: arrangement, columns: 2, cardIDs: [id], form: "card")),
                .offset(1_080)
            )
        }
    }

    func testRemovingTheOnlyVisibleCardRevealsItsFirstPhoto() {
        let tracker = DayGridAnchorTracker()
        let id = "place-card:p"
        let old = [id: CGRect(x: 0, y: 100, width: 300, height: 400)]
        update(tracker, old, revision(arrangement: .aligned, cardIDs: [id], fallbacks: [id: "a"], form: "card"))
        let titles = revision(arrangement: .aligned)
        XCTAssertEqual(update(tracker, [:], titles), .reveal("a"))
        XCTAssertNil(update(tracker, [:], titles))
        XCTAssertEqual(update(tracker, frames(200, 400), titles), .offset(1_100))
    }

    func testMissingLazyPlaceCardIsRevealedByItsOwnID() {
        let tracker = DayGridAnchorTracker()
        let id = "place-card:p"
        let old = [id: CGRect(x: 0, y: 100, width: 140, height: 190)]
        update(tracker, old, revision(cardIDs: [id], form: "card"))
        let aligned = revision(arrangement: .aligned, cardIDs: [id], form: "card")
        XCTAssertEqual(update(tracker, [:], aligned), .reveal(id))
        XCTAssertNil(update(tracker, [:], aligned))
        let new = [id: CGRect(x: 0, y: 180, width: 140, height: 190)]
        XCTAssertEqual(update(tracker, new, aligned), .offset(1_080))
    }

    func testDeletedCardAndPhotoDoNotProduceAnImpossibleReveal() {
        let tracker = DayGridAnchorTracker()
        let id = "place-card:p"
        update(tracker, [id: CGRect(x: 0, y: 100, width: 300, height: 400)],
               revision(cardIDs: [id], fallbacks: [id: "a"], form: "card"))
        XCTAssertNil(update(tracker, [:], revision(ids: [])))
    }

    func testNameOnlyCardUpdatesDoNotRestoreOldScrollPositions() {
        let tracker = DayGridAnchorTracker()
        let id = "place-card:p"
        let revision = revision(arrangement: .aligned, cardIDs: [id], form: "card")
        update(tracker, [id: CGRect(x: 0, y: 100, width: 140, height: 190)], revision)
        XCTAssertNil(update(tracker, [id: CGRect(x: 0, y: 70, width: 140, height: 190)], revision))
    }

    func testSwitchingCardFlowPreservesTheVisiblePhoto() {
        let tracker = DayGridAnchorTracker()
        update(tracker, frames(120, 400), revision(cardIDs: ["place-card:p"], form: "card"))
        let continuous = revision(cardIDs: ["place-card:p"], form: "card", flow: .continuous)
        XCTAssertEqual(update(tracker, frames(80, 250), continuous), .offset(960))
        XCTAssertNil(update(tracker, frames(120, 290), continuous, offset: 960))
        XCTAssertEqual(
            update(tracker, frames(200, 500), revision(cardIDs: ["place-card:p"], form: "card")),
            .offset(1_080)
        )
    }

    func testSwitchingCardFlowPreservesAnOnlyVisiblePlaceCard() {
        let tracker = DayGridAnchorTracker()
        let id = "place-card:p"
        update(tracker, [id: CGRect(x: 0, y: 100, width: 300, height: 400)],
               revision(cardIDs: [id], form: "card"))
        XCTAssertEqual(
            update(tracker, [id: CGRect(x: 0, y: 300, width: 300, height: 400)],
                   revision(cardIDs: [id], form: "card", flow: .continuous)),
            .offset(1_200)
        )
    }
}
