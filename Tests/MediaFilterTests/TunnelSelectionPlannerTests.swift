import Foundation
import XCTest
@testable import MediaFilter

final class TunnelSelectionPlannerTests: XCTestCase {
    private func date(_ value: Int) -> Date { Date(timeIntervalSince1970: Double(value) * 86400) }

    private func day(_ value: Int, _ ids: [String], count: Int = 3) -> TunnelCandidateDay {
        TunnelCandidateDay(date: date(value), assetIdentifiers: ids, previewCount: count)
    }

    private func select(
        _ candidates: [TunnelCandidateDay], previous: [TunnelDaySelection] = [],
        limit: Int = 40, newestFirst: Bool = false
    ) -> [TunnelDaySelection] {
        TunnelSelectionPlanner.select(
            from: candidates, preserving: previous, minimumCount: 3,
            maximumDays: limit, newestFirst: newestFirst
        )
    }

    func testInitialSelectionKeepsAnchorAndEligibilityLimits() {
        let plan = select([
            day(2, ["b1", "b2", "b3"]),
            day(4, ["anchor"]),
            day(3, ["too-few-1", "too-few-2"]),
            day(1, ["a1", "a2", "a3"])
        ])
        XCTAssertEqual(plan.map(\.date), [date(4), date(2), date(1)])
        XCTAssertEqual(plan.first?.assetIdentifiers, ["anchor"])
        let many = (1...50).map { day($0, ["\($0)-1", "\($0)-2", "\($0)-3"]) }
        XCTAssertEqual(select(many).count, 40)
        XCTAssertEqual(select(many).first?.date, date(50))
        XCTAssertTrue(select([], limit: 40).isEmpty)
        XCTAssertTrue(select(many, limit: 0).isEmpty)
        XCTAssertEqual(select(many, limit: 1).map(\.date), [date(50)])
    }

    func testUnchangedFiltersKeepDatesSamplesAndOrderExactly() {
        let candidates = [
            day(2, ["b1", "b2", "b3", "b4"]),
            day(4, ["anchor1", "anchor2", "anchor3"]),
            day(1, ["a1", "a2", "a3"]),
            day(3, ["c1", "c2", "c3"])
        ]
        let initial = select(candidates, limit: 3)
        XCTAssertEqual(select(candidates, previous: initial, limit: 3), initial)
        let newPriority = Array(candidates.reversed())
        XCTAssertEqual(select(newPriority, previous: initial, limit: 3), initial)
    }

    func testOnlyExcludedPhotosAreReplacedWithinRetainedDay() {
        let previous = [
            TunnelDaySelection(date: date(4), assetIdentifiers: ["anchor"]),
            TunnelDaySelection(date: date(2), assetIdentifiers: ["b2", "video", "b1"])
        ]
        let result = select([
            day(4, ["anchor"]),
            day(2, ["b1", "b2", "b3", "b4"])
        ], previous: previous)
        XCTAssertEqual(result.map(\.date), previous.map(\.date))
        XCTAssertEqual(result[1].assetIdentifiers, ["b2", "b1", "b3"])
        // These are the only identifiers requiring new thumbnail requests.
        let loaded = Set(previous.flatMap(\.assetIdentifiers))
        XCTAssertEqual(result.flatMap(\.assetIdentifiers).filter { !loaded.contains($0) }, ["b3"])
    }

    func testEligibleDaysSurviveAndOnlyInvalidSlotIsReplaced() {
        let previous = [
            TunnelDaySelection(date: date(5), assetIdentifiers: ["anchor"]),
            TunnelDaySelection(date: date(1), assetIdentifiers: ["a1", "a2", "a3"]),
            TunnelDaySelection(date: date(3), assetIdentifiers: ["c1", "c2", "c3"]),
            TunnelDaySelection(date: date(2), assetIdentifiers: ["b1", "b2", "b3"])
        ]
        let result = select([
            day(2, ["b1", "b2", "b3"]),
            day(5, ["anchor"]),
            day(4, ["replacement1", "replacement2", "replacement3"]),
            day(1, ["a1", "a2", "a3"]),
            day(3, ["only-two", "items"])
        ], previous: previous, limit: 4)
        XCTAssertEqual(result.map(\.date), [date(5), date(1), date(4), date(2)])
        XCTAssertEqual(result[1], previous[1])
        XCTAssertEqual(result[3], previous[3])
        XCTAssertEqual(Set(result.map(\.date)).count, result.count)
    }

    func testEnablingCategoryAddsCandidatesWithoutDiscardingExistingDates() {
        let initial = select([
            day(4, ["anchor"]),
            day(2, ["photo1", "photo2", "photo3"])
        ])
        let expanded = select([
            day(1, ["video1", "video2", "video3"]),
            day(4, ["anchor", "extra1", "extra2"]),
            day(3, ["screen1", "screen2", "screen3"]),
            day(2, ["photo1", "photo2", "photo3", "video4"])
        ], previous: initial)
        XCTAssertEqual(expanded.map(\.date), [date(4), date(2), date(1), date(3)])
        XCTAssertEqual(expanded[1], initial[1])
        XCTAssertEqual(expanded.first?.assetIdentifiers.first, "anchor")
    }

    func testNewAnchorAndReverseOrderKeepSurvivingSamples() {
        let initial = select([
            day(1, ["a1", "a2", "a3"]),
            day(3, ["c1", "c2", "c3"]),
            day(2, ["b1", "b2", "b3"])
        ])
        let result = select([
            day(4, ["new-anchor"]),
            day(1, ["a1", "a2", "a3"]),
            day(3, ["c1", "c2", "c3"]),
            day(2, ["b1", "b2", "b3"])
        ], previous: initial, newestFirst: true)
        XCTAssertEqual(result.map(\.date), [date(4), date(3), date(2), date(1)])
        XCTAssertEqual(result[1], initial[0])
    }

    func testEmptyFilterCanRecoverFromSameCandidateIndex() {
        let candidates = [day(2, ["p1", "p2", "p3"]), day(1, ["p4", "p5", "p6"])]
        let initial = select(candidates)
        let empty = select(candidates.map { TunnelCandidateDay(date: $0.date, assetIdentifiers: [], previewCount: 3) },
                           previous: initial)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(select(candidates, previous: empty), initial)
    }

    func testRemappingKeepsFocusedDayAndFractionalOffsetAfterInsertion() {
        let old = [date(5), date(3), date(1)]
        let new = [date(6), date(5), date(4), date(3), date(1)]
        let progress = 1.2 // spacing 2, focus index 1, plus 0.2 offset
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            progress, oldDates: old, newDates: new, spacing: 2
        ), 5.2, accuracy: 0.0001)
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            progress, oldDates: old, newDates: old, spacing: 2
        ), progress, accuracy: 0.0001)
    }

    func testRemovedFocusUsesSurvivingNeighbourWithoutJumpingToBeginning() {
        let old = [date(6), date(5), date(4), date(3), date(2), date(1)]
        let new = [date(6), date(5), date(3), date(2), date(1)]
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            3, oldDates: old, newDates: new, spacing: 2
        ), 3, accuracy: 0.0001)
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            9, oldDates: old, newDates: [], spacing: 2
        ), -1)
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            -1, oldDates: [], newDates: new, spacing: 2
        ), -1)
    }

    func testRepeatedCategoryChangesKeepSurvivingDatesAndValidSamples() {
        let base = (1...20).map { value in
            day(value, (0..<8).map { "\(value)-\($0 % 4)-\($0)" }, count: 4)
        }
        var previous = select(base)
        for mask in [1, 3, 7, 15, 5, 0, 15, 2, 10, 15] {
            let candidates = base.map { day in
                TunnelCandidateDay(
                    date: day.date,
                    assetIdentifiers: day.assetIdentifiers.filter {
                        let category = Int($0.split(separator: "-")[1])!
                        return mask & (1 << category) != 0
                    },
                    previewCount: day.previewCount
                )
            }
            let current = select(candidates, previous: previous)
            XCTAssertEqual(Set(current.map(\.date)).count, current.count)
            let candidatesByDate = Dictionary(uniqueKeysWithValues: candidates.map { ($0.date, $0) })
            let currentByDate = Dictionary(uniqueKeysWithValues: current.map { ($0.date, $0) })
            for old in previous {
                let available = candidatesByDate[old.date]!.assetIdentifiers
                if available.count >= 3 {
                    XCTAssertNotNil(currentByDate[old.date])
                    let kept = old.assetIdentifiers.filter { available.contains($0) }
                    XCTAssertEqual(Array(currentByDate[old.date]!.assetIdentifiers.prefix(kept.count)), kept)
                }
            }
            for selection in current {
                let available = candidatesByDate[selection.date]!.assetIdentifiers
                XCTAssertTrue(selection.assetIdentifiers.allSatisfy { available.contains($0) })
            }
            previous = current
        }
    }

    func testProgressRemapsByDateWhenOrderChangesAndClampsAtEdges() {
        let old = [date(5), date(2), date(4), date(1), date(3)]
        let sorted = [date(5), date(4), date(3), date(2), date(1)]
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            5.25, oldDates: old, newDates: sorted, spacing: 2
        ), 7, accuracy: 0.0001) // date(1) moved to the last slot; clamp its offset.
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            3.25, oldDates: old, newDates: sorted, spacing: 2
        ), 1.25, accuracy: 0.0001)
        XCTAssertEqual(TunnelSelectionPlanner.remapProgress(
            20, oldDates: old, newDates: [date(5)], spacing: 2
        ), -1)
    }
}
