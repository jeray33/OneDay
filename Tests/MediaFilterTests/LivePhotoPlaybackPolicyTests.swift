import XCTest
@testable import MediaFilter

final class LivePhotoPlaybackPolicyTests: XCTestCase {
    func testCachedPageDetectsNewVisitWithoutReceivingDeselection() {
        var policy = LivePhotoPlaybackPolicy()
        let firstVisit = UUID()
        policy.select(true, visitID: firstVisit)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
        policy.select(true, visitID: firstVisit)
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
        policy.select(true, visitID: UUID())
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testPrecreatedNeighborNeverPlays() {
        var policy = LivePhotoPlaybackPolicy()
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
        XCTAssertFalse(policy.begin(.manual, ready: true, permitted: true))
        XCTAssertFalse(policy.hasPlayed)
    }

    func testFirstVisitPlaysOnlyOnceDespiteRefreshes() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
        policy.select(true)
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testLateResourceDoesNotConsumePendingAutoplay() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertFalse(policy.begin(.automatic, ready: false, permitted: true))
        XCTAssertFalse(policy.hasPlayed)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testBlockedPlaybackWaitsUntilPreviewIsStable() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: false))
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testInterruptionDoesNotReplayOnResume() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: false))
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
        XCTAssertFalse(policy.begin(.manual, ready: true, permitted: false))
        XCTAssertTrue(policy.begin(.manual, ready: true, permitted: true))
    }

    func testLeavingAndReturningStartsANewVisit() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
        policy.select(false)
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
        policy.select(true)
        XCTAssertTrue(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testRapidlySkippedPageCannotPlayAfterResourceArrives() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertFalse(policy.begin(.automatic, ready: false, permitted: false))
        policy.select(false)
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
    }

    func testManualReplayTakesPrecedenceAndCanRepeat() {
        var policy = LivePhotoPlaybackPolicy()
        policy.select(true)
        XCTAssertTrue(policy.begin(.manual, ready: true, permitted: true))
        XCTAssertFalse(policy.begin(.automatic, ready: true, permitted: true))
        XCTAssertTrue(policy.begin(.manual, ready: true, permitted: true))
        XCTAssertTrue(LivePhotoPlaybackPolicy.Source.automatic.isMuted)
        XCTAssertFalse(LivePhotoPlaybackPolicy.Source.manual.isMuted)
    }
}
