import XCTest
@testable import MediaFilter

final class VideoSimilarityTests: XCTestCase {
    func testSamplesCoverBeginningMiddleAndEnd() {
        XCTAssertEqual(VideoSimilarityPolicy.sampleTimes(duration: 10), [1, 5, 9])
        XCTAssertEqual(VideoSimilarityPolicy.sampleTimes(duration: 0.5).count, 3)
    }

    func testInvalidOrTooShortVideosAreSkipped() {
        for duration in [0, -1, 0.4, Double.nan, .infinity] {
            XCTAssertTrue(VideoSimilarityPolicy.sampleTimes(duration: duration).isEmpty)
            XCTAssertFalse(VideoSimilarityPolicy.compatibleDurations(duration, 10))
        }
    }

    func testDurationToleranceIsBounded() {
        XCTAssertTrue(VideoSimilarityPolicy.compatibleDurations(10, 11))
        XCTAssertFalse(VideoSimilarityPolicy.compatibleDurations(10, 12))
        XCTAssertTrue(VideoSimilarityPolicy.compatibleDurations(100, 102))
        XCTAssertFalse(VideoSimilarityPolicy.compatibleDurations(100, 103))
        XCTAssertTrue(VideoSimilarityPolicy.compatibleDurations(0.5, 0.8))
    }

    func testEveryFrameMustMatch() {
        XCTAssertEqual(VideoSimilarityPolicy.distance([0.1, 0.2, 0.25]), 0.25)
        // A matching cover cannot mask a different middle or ending.
        XCTAssertEqual(VideoSimilarityPolicy.distance([0.01, 0.9, 0.01]), 0.9)
    }

    func testIncompleteAndInvalidSamplesCannotMatch() {
        for values: [Float] in [[], [0.1], [0.1, 0.2], [0, 0, .nan],
                                [0, .infinity, 0], [-0.1, 0, 0], [0, 0, 0, 0]] {
            XCTAssertNil(VideoSimilarityPolicy.distance(values))
        }
    }

    func testVideoGroupsStaySeparateFromPhotos() {
        let videos: Set<Int> = [0, 1, 3, 4]
        let groups = SimilarPhotoGrouping.groups(
            [0, 1, 2, 3, 4], level: .nearDuplicate,
            date: { Date(timeIntervalSince1970: Double($0)) },
            eligible: { _ in true }, distance: { _, _ in 0.1 },
            compatible: { videos.contains($0) == videos.contains($1) })
        XCTAssertEqual(groups, [[0, 1], [2], [3, 4]])
    }

    func testChangedEndingPreventsFolding() {
        let groups = SimilarPhotoGrouping.groups(
            [0, 1], level: .sameScene,
            date: { Date(timeIntervalSince1970: Double($0)) },
            eligible: { _ in true },
            distance: { _, _ in VideoSimilarityPolicy.distance([0.1, 0.1, 0.8]) })
        XCTAssertEqual(groups, [[0], [1]])
    }
}
