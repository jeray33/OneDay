import XCTest
@testable import MediaFilter

final class SimilarPhotoGroupingTests: XCTestCase {
    private func groups(
        _ items: [Int] = [0, 1, 2], level: SimilarPhotoFolding = .nearDuplicate,
        missing: Set<Int> = [], video: Set<Int> = [],
        seconds: Double = 1, distance: Float = 0.1,
        nearby: Bool = true
    ) -> [[Int]] {
        SimilarPhotoGrouping.groups(
            items, level: level,
            date: { Date(timeIntervalSince1970: Double($0) * seconds) },
            eligible: { !video.contains($0) },
            distance: { a, b in
                missing.contains(a) || missing.contains(b) ? nil : distance
            }, nearby: { _, _ in nearby })
    }

    func testEmptyAndSingleton() {
        XCTAssertEqual(groups([]), [])
        XCTAssertEqual(groups([0]), [[0]])
    }
    func testOffPreservesEveryItem() {
        XCTAssertEqual(groups(level: .off), [[0], [1], [2]])
    }
    func testNearDuplicatesMergeInOrder() {
        XCTAssertEqual(groups(), [[0, 1, 2]])
    }
    func testVideoAndMissingFeaturesBreakGroups() {
        XCTAssertEqual(groups(video: [1]), [[0], [1], [2]])
        XCTAssertEqual(groups(missing: [1]), [[0], [1], [2]])
    }
    func testTotalTimeWindowPreventsLongChains() {
        XCTAssertEqual(groups(seconds: 20), [[0, 1], [2]])
    }
    func testSceneLevelIsBroader() {
        XCTAssertEqual(groups(distance: 0.4), [[0], [1], [2]])
        XCTAssertEqual(groups(level: .sameScene, distance: 0.4), [[0, 1, 2]])
    }
    func testRelaxedThresholdsAcceptMoreMatches() {
        XCTAssertEqual(groups(distance: 0.25), [[0, 1, 2]])
        XCTAssertEqual(groups(level: .sameScene, distance: 0.45), [[0, 1, 2]])
    }
    func testThresholdBoundary() {
        for level in [SimilarPhotoFolding.nearDuplicate, .sameScene] {
            XCTAssertEqual(groups(level: level, distance: level.threshold), [[0, 1, 2]])
            XCTAssertEqual(groups(level: level, distance: level.threshold + 0.01), [[0], [1], [2]])
        }
    }
    func testLocationAndInvalidDistancePreventMerge() {
        XCTAssertEqual(groups(nearby: false), [[0], [1], [2]])
        XCTAssertEqual(groups(distance: .nan), [[0], [1], [2]])
        XCTAssertEqual(groups(distance: .infinity), [[0], [1], [2]])
    }
    func testFirstMemberStopsVisualDrift() {
        let result = SimilarPhotoGrouping.groups(
            [0, 1, 2], level: .nearDuplicate,
            date: { Date(timeIntervalSince1970: Double($0)) },
            eligible: { _ in true },
            distance: { Float(abs($0 - $1)) * 0.18 })
        XCTAssertEqual(result, [[0, 1], [2]])
    }
    func testMissingDateDoesNotMerge() {
        let result = SimilarPhotoGrouping.groups(
            [0, 1], level: .sameScene, date: { _ in nil },
            eligible: { _ in true }, distance: { _, _ in 0 })
        XCTAssertEqual(result, [[0], [1]])
    }

    func testBroaderPresetsStillRespectThresholdAndTotalTimeWindow() {
        XCTAssertEqual(groups(level: .sameScene, distance: 0.58), [[0], [1], [2]])
        XCTAssertEqual(groups(level: .loose, distance: 0.58), [[0, 1, 2]])
        XCTAssertEqual(groups(level: .loose, distance: 0.70), [[0], [1], [2]])
        XCTAssertEqual(groups(level: .veryLoose, distance: 0.70), [[0, 1, 2]])
        XCTAssertEqual(groups(level: .loose, seconds: 200), [[0, 1], [2]])
        XCTAssertEqual(groups(level: .veryLoose, seconds: 200), [[0, 1, 2]])
    }

    func testCustomParametersControlGroupingAndOffStillWins() {
        func custom(_ threshold: Float, _ window: TimeInterval, level: SimilarPhotoFolding = .custom) -> [[Int]] {
            SimilarPhotoGrouping.groups(
                [0, 1, 2], level: level, parameters: .init(threshold: threshold, window: window),
                date: { Date(timeIntervalSince1970: Double($0) * 200) },
                eligible: { _ in true }, distance: { _, _ in 0.58 })
        }
        XCTAssertEqual(custom(0.60, 300), [[0, 1], [2]])
        XCTAssertEqual(custom(0.60, 600), [[0, 1, 2]])
        XCTAssertEqual(custom(0.40, 600), [[0], [1], [2]])
        XCTAssertEqual(custom(0.80, 600, level: .off), [[0], [1], [2]])
    }
}
