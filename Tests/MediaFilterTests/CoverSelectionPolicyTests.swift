import XCTest
@testable import MediaFilter

final class CoverSelectionPolicyTests: XCTestCase {
    func testSamplesAreBoundedUniqueAndIncludeBothEnds() {
        for count in [1, 2, 24, 25, 300, 10_000] {
            let indices = CoverSelectionPolicy.sampleIndices(count: count)
            XCTAssertEqual(indices.count, min(count, 24))
            XCTAssertEqual(Set(indices).count, indices.count)
            XCTAssertEqual(indices.first, 0)
            XCTAssertEqual(indices.last, count - 1)
        }
    }

    func testEmptyAndSingleSampleLimits() {
        XCTAssertEqual(CoverSelectionPolicy.sampleIndices(count: 0), [])
        XCTAssertEqual(CoverSelectionPolicy.sampleIndices(count: 50, limit: 0), [])
        XCTAssertEqual(CoverSelectionPolicy.sampleIndices(count: 50, limit: 1), [0])
    }

    func testDeadlineWithoutScoresFallsBackToFirstPhoto() {
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(scores: [:], count: 24, top: 2), [0, 1])
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(scores: [:], count: 1, top: 2), [0])
    }

    func testPartialScoresWinAndTiesStayChronological() {
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(
            scores: [8: 42, 3: 42, 5: 12], count: 24, top: 2), [3, 8])
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(
            scores: [8: 42], count: 24, top: 2), [8, 0])
    }

    func testCoverCategoryPrefersCameraMediaThenOtherImagesThenScreenshots() {
        XCTAssertEqual(CoverSelectionPolicy.coverCategoryPriority, [.photoVideo, .otherImage, .screenshot])
        XCTAssertEqual(
            CoverSelectionPolicy.coverCategory(among: [MediaCategory.screenshot, .otherImage, .photoVideo]),
            .photoVideo
        )
        XCTAssertEqual(
            CoverSelectionPolicy.coverCategory(among: [MediaCategory.screenshot, .otherImage]),
            .otherImage
        )
        XCTAssertEqual(
            CoverSelectionPolicy.coverCategory(among: [MediaCategory.screenshot]),
            .screenshot
        )
        XCTAssertNil(CoverSelectionPolicy.coverCategory(among: [MediaCategory]()))
    }

    func testInvalidScoresAndEmptyInputsAreIgnored() {
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(
            scores: [-1: 99, 50: 99, 2: .nan], count: 3, top: 2), [0, 1])
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(scores: [:], count: 0, top: 2), [])
        XCTAssertEqual(CoverSelectionPolicy.rankedIndices(scores: [:], count: 3, top: 0), [])
    }
}
