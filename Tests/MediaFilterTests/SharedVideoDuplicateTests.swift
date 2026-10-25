import XCTest
@testable import MediaFilter

final class SharedVideoDuplicateTests: XCTestCase {
    func testOnlyNonemptyEqualVerifiedDigestsConfirmCopies() {
        XCTAssertTrue(SharedVideoDuplicatePolicy.contentMatches(
            digestA: "same-file", digestB: "same-file"))
        XCTAssertFalse(SharedVideoDuplicatePolicy.contentMatches(
            digestA: "different-ending", digestB: "same-scene"))
        XCTAssertFalse(SharedVideoDuplicatePolicy.contentMatches(digestA: nil, digestB: nil))
        XCTAssertFalse(SharedVideoDuplicatePolicy.contentMatches(digestA: "file", digestB: nil))
        XCTAssertFalse(SharedVideoDuplicatePolicy.contentMatches(digestA: "", digestB: ""))
    }

    func testReencodedPicturesMatchButDifferentClipsDoNot() {
        // Measured: shared-album re-encodes 0.035...0.126, unrelated clips >= 0.384.
        XCTAssertTrue(SharedVideoDuplicatePolicy.perceptualMatch([0, 0, 0]))
        XCTAssertTrue(SharedVideoDuplicatePolicy.perceptualMatch([0.065, 0.101, 0.126]))
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([0.384]))
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([0.05, 0.05, 0.3]))
    }

    func testMissingOrInvalidPictureDistancesNeverMatch() {
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([]))
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([.nan]))
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([-0.1]))
        XCTAssertFalse(SharedVideoDuplicatePolicy.perceptualMatch([0.01, .infinity]))
    }

    func testCaptureTimeNeverConfirmsVideoOwnership() {
        XCTAssertFalse(SharedCopyMatch.isOwnCopy(
            sharedTime: 100, isVideo: true, sharedNames: { ["IMG_1.MOV"] },
            ownSeconds: [100], ownSortedTimes: [100], ownNames: { _ in ["IMG_1.MOV"] }))
    }

    func testOwnOriginalAlwaysWinsOverSharedCopy() async {
        var own = video("original", width: 1280, height: 720)
        own.isShared = false
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("shared"), own]) { _, _ in true }
        XCTAssertEqual(result, ["shared"])
    }

    func testTwoPersonalVideosAreNeverSuppressed() async {
        var a = video("a")
        var b = video("b")
        a.isShared = false
        b.isShared = false
        let result = await SharedVideoDuplicatePolicy.duplicateIDs([a, b]) { _, _ in
            XCTFail("Personal videos must not trigger verification")
            return true
        }
        XCTAssertTrue(result.isEmpty)
    }

    private func video(_ id: String, time: Double = 100, duration: Double = 10,
                       width: Int = 1920, height: Int = 1080) -> SharedVideoDuplicatePolicy.Candidate {
        .init(id: id, time: time, duration: duration, width: width, height: height)
    }

    func testSameIDIsKeptOnceWithoutChangingOrder() {
        XCTAssertEqual(SharedVideoDuplicatePolicy.unique(["b", "a", "b"], id: { $0 }), ["b", "a"])
    }

    func testMetadataSelectsCandidatesAcrossResolutions() {
        XCTAssertTrue(SharedVideoDuplicatePolicy.compatible(
            video("a"), video("b", time: 100.6, width: 1280, height: 720)))
        XCTAssertFalse(SharedVideoDuplicatePolicy.compatible(video("a"), video("a")))
        XCTAssertFalse(SharedVideoDuplicatePolicy.compatible(video("a"), video("b", time: 102)))
        XCTAssertFalse(SharedVideoDuplicatePolicy.compatible(video("a"), video("b", duration: 11)))
        XCTAssertFalse(SharedVideoDuplicatePolicy.compatible(video("a"), video("b", width: 1080, height: 1920)))
    }

    func testInvalidMetadataCannotMatch() {
        for invalid in [video("b", time: .nan), video("b", duration: .infinity),
                        video("b", duration: 0), video("b", width: 0)] {
            XCTAssertFalse(SharedVideoDuplicatePolicy.compatible(video("a"), invalid))
        }
    }

    func testUnconfirmedCopiesStayVisible() async {
        let result = await SharedVideoDuplicatePolicy.duplicateIDs([video("a"), video("b")]) { _, _ in false }
        XCTAssertTrue(result.isEmpty)
    }

    func testHigherResolutionWinsRegardlessOfInputOrder() async {
        let low = video("a", width: 1280, height: 720)
        let high = video("b")
        for input in [[low, high], [high, low]] {
            let result = await SharedVideoDuplicatePolicy.duplicateIDs(input) { _, _ in true }
            XCTAssertEqual(result, ["a"])
        }
    }

    func testNonAdjacentCopiesAreCompared() async {
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("unrelated", time: 200), video("b")]) { _, _ in true }
        XCTAssertEqual(result, ["b"])
    }

    func testMetadataAloneDoesNotHideDifferentContent() async {
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("different-ending"), video("different-audio")]) { _, _ in false }
        XCTAssertTrue(result.isEmpty)
    }

    func testGroupsCannotChainAcrossUnmatchedMembers() async {
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("b"), video("c")]) { a, b in Set([a.id, b.id]) != ["b", "c"] }
        XCTAssertEqual(result, ["b"])
    }

    func testNoNetworkWorkForIncompatibleCandidates() async {
        var comparisons = 0
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("b", time: 300)]) { _, _ in comparisons += 1; return true }
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(comparisons, 0)
    }

    func testCancelledScanDoesNotConfirmDuplicates() async {
        let task = Task {
            await SharedVideoDuplicatePolicy.duplicateIDs([video("a"), video("b")]) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
    }

    func testConfirmedCopiesPublishProgressWithoutWaitingForWholeScan() async {
        var updates: [Set<String>] = []
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("b"), video("c")],
            onUpdate: { updates.append($0) }) { _, _ in true }
        XCTAssertEqual(updates, [Set(["b"]), Set(["b", "c"])])
        XCTAssertEqual(result, updates.last)
    }

    func testUnverifiedCandidatesNeverPublishHiddenIDs() async {
        let result = await SharedVideoDuplicatePolicy.duplicateIDs(
            [video("a"), video("b")], onUpdate: { _ in XCTFail("No verified copy") }) { _, _ in false }
        XCTAssertTrue(result.isEmpty)
    }
}
