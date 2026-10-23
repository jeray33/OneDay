import XCTest
@testable import MediaFilter

final class SharedCopyMatchTests: XCTestCase {
    private func isOwn(
        _ sharedTime: TimeInterval, names sharedNames: [String] = ["IMG_5243.HEIC"],
        own: [(TimeInterval, [String])]
    ) -> Bool {
        let sorted = own.sorted { $0.0 < $1.0 }
        return SharedCopyMatch.isOwnCopy(
            sharedTime: sharedTime,
            sharedNames: { sharedNames },
            ownSeconds: Set(sorted.map { SharedCopyMatch.captureSecond($0.0) }),
            ownSortedTimes: sorted.map(\.0),
            ownNames: { sorted[$0].1 })
    }

    func testSameRoundedSecondMatchesWithoutNames() {
        XCTAssertTrue(isOwn(1_000.2, names: [], own: [(1_000.4, ["IMG_1.HEIC"])]))
    }

    func testWholeSecondCopyRoundingToNeighborMatchesBySameName() {
        // Real case: original …107.40, shared copy …108.0.
        XCTAssertTrue(isOwn(1_608_555_108.0, own: [(1_608_555_107.4035, ["IMG_5243.HEIC"])]))
    }

    func testNameComparisonIgnoresExtensionAndCase() {
        XCTAssertTrue(isOwn(2_000.0, names: ["img_5243.jpg"], own: [(1_999.4, ["IMG_5243.HEIC"])]))
    }

    func testNearCaptureWithDifferentNameStaysForeign() {
        XCTAssertFalse(isOwn(3_000.0, names: ["IMG_0001.HEIC"], own: [(2_999.4, ["IMG_5243.HEIC"])]))
    }

    func testSameNameOutsideToleranceStaysForeign() {
        XCTAssertFalse(isOwn(4_000.0, own: [(3_998.6, ["IMG_5243.HEIC"])]))
    }

    func testMissingSharedNamesStayForeign() {
        XCTAssertFalse(isOwn(5_000.0, names: [], own: [(4_999.4, ["IMG_5243.HEIC"])]))
    }

    func testNamesAreReadOnlyForNearCaptures() {
        var reads = 0
        let matched = SharedCopyMatch.isOwnCopy(
            sharedTime: 6_000, sharedNames: { reads += 1; return ["A.HEIC"] },
            ownSeconds: [9_000], ownSortedTimes: [9_000], ownNames: { _ in reads += 1; return ["A.HEIC"] })
        XCTAssertFalse(matched)
        XCTAssertEqual(reads, 0)
    }

    func testNearbyIndicesIncludeBothBoundaries() {
        let times: [TimeInterval] = [8.9, 9.0, 9.5, 10.0, 11.0, 11.1]
        XCTAssertEqual(SharedCopyMatch.nearbyIndices(of: 10.0, in: times), 1..<5)
        XCTAssertEqual(SharedCopyMatch.nearbyIndices(of: 20.0, in: times), 6..<6)
    }
}
