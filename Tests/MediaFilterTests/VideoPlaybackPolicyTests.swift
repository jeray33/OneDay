import XCTest
@testable import MediaFilter

final class VideoPlaybackPolicyTests: XCTestCase {
    func testLoadingAndBecomingVisibleNeverAutoplay() {
        var policy = VideoPlaybackPolicy()
        XCTAssertFalse(policy.isPlaying)
        policy.permit(true)
        XCTAssertFalse(policy.isPlaying)
        XCTAssertTrue(policy.play(ready: true))
    }

    func testHiddenOrUnreadyVideoCannotPlayOrScrub() {
        var policy = VideoPlaybackPolicy()
        XCTAssertFalse(policy.play(ready: true))
        XCTAssertFalse(policy.beginScrubbing(ready: true))
        policy.permit(true)
        XCTAssertFalse(policy.play(ready: false))
        XCTAssertFalse(policy.beginScrubbing(ready: false))
    }

    func testLosingEligibilityPausesAndDoesNotResumeOnReturn() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        policy.permit(false)
        XCTAssertFalse(policy.isPlaying)
        policy.permit(true)
        XCTAssertFalse(policy.isPlaying)
    }

    func testScrubbingPlayingVideoResumesOnlyAfterSeek() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        XCTAssertTrue(policy.beginScrubbing(ready: true))
        XCTAssertFalse(policy.isPlaying)
        XCTAssertTrue(policy.isScrubbing)
        XCTAssertFalse(policy.play(ready: true))
        XCTAssertTrue(policy.endScrubbing())
        XCTAssertFalse(policy.isPlaying)
        XCTAssertFalse(policy.isScrubbing)
        XCTAssertTrue(policy.canResumeSeek(revision: policy.revision))
    }

    func testScrubbingPausedVideoDoesNotStartPlayback() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.beginScrubbing(ready: true)
        XCTAssertFalse(policy.endScrubbing())
        XCTAssertFalse(policy.isPlaying)
    }

    func testDuplicateTouchBeginDoesNotForgetPlaybackIntent() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        XCTAssertTrue(policy.beginScrubbing(ready: true))
        XCTAssertFalse(policy.beginScrubbing(ready: true))
        XCTAssertTrue(policy.endScrubbing())
        XCTAssertFalse(policy.endScrubbing())
    }

    func testInterruptionDuringScrubCancelsResumeEvenAfterReturning() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        policy.beginScrubbing(ready: true)
        let revision = policy.revision
        policy.permit(false)
        policy.permit(true)
        XCTAssertFalse(policy.isScrubbing)
        XCTAssertFalse(policy.endScrubbing())
        XCTAssertFalse(policy.canResumeSeek(revision: revision))
    }

    func testLateSeekCannotResumeAfterPauseOrPageChange() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        policy.beginScrubbing(ready: true)
        XCTAssertTrue(policy.endScrubbing())
        let revision = policy.revision
        policy.pause()
        XCTAssertFalse(policy.canResumeSeek(revision: revision))
        policy.play(ready: true)
        XCTAssertFalse(policy.canResumeSeek(revision: revision))
    }

    func testNewScrubInvalidatesPriorSeekCompletion() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.beginScrubbing(ready: true)
        let revision = policy.revision
        XCTAssertFalse(policy.endScrubbing())
        policy.beginScrubbing(ready: true)
        XCTAssertFalse(policy.canResumeSeek(revision: revision))
    }

    func testPermissionRefreshDoesNotPausePlayingZoomedVideo() {
        var policy = VideoPlaybackPolicy()
        policy.permit(true)
        policy.play(ready: true)
        policy.permit(true)
        XCTAssertTrue(policy.isPlaying)
    }

    func testInvalidDurationsDisableTheTimeline() {
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(VideoPlaybackPolicy.validDuration(duration), 0)
            XCTAssertEqual(VideoPlaybackPolicy.clampedTime(10, duration: duration), 0)
        }
        XCTAssertEqual(VideoPlaybackPolicy.validDuration(0.1), 0.1)
    }

    func testSeekingClampsBothEndsAndInvalidValues() {
        XCTAssertEqual(VideoPlaybackPolicy.clampedTime(-1, duration: 10), 0)
        XCTAssertEqual(VideoPlaybackPolicy.clampedTime(99, duration: 10), 10)
        XCTAssertEqual(VideoPlaybackPolicy.clampedTime(4.25, duration: 10), 4.25)
        XCTAssertEqual(VideoPlaybackPolicy.clampedTime(.nan, duration: 10), 0)
        XCTAssertEqual(VideoPlaybackPolicy.clampedTime(.infinity, duration: 10), 0)
    }

    func testTimelineLabelsSupportShortLongAndUnknownVideos() {
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(0), "00:00")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(0.9), "00:00")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(92.5), "01:32")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(3599), "59:59")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(3600), "1:00:00")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(360005), "100:00:05")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(.nan), "00:00")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(.infinity), "00:00")
        XCTAssertEqual(VideoPlaybackPolicy.timeLabel(-2), "00:00")
    }

    func testTrackFillMatchesPlaybackWithoutAThumb() {
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: 25, duration: 100), 0.25)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: -5, duration: 100), 0)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: 120, duration: 100), 1)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: 0.1, duration: 0.2), 0.5)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: .nan, duration: 100), 0)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: 10, duration: .infinity), 0)
        XCTAssertEqual(VideoPlaybackPolicy.progress(position: 10, duration: 0), 0)
    }

    func testDraggingAnywhereOnTrackSeeksByHorizontalPosition() {
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 0, width: 200, duration: 60), 0)
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 50, width: 200, duration: 60), 15)
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 200, width: 200, duration: 60), 60)
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: -50, width: 200, duration: 60), 0)
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 250, width: 200, duration: 60), 60)
        XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 100, width: 200, duration: 0.2), 0.1)
    }

    func testInvalidTrackGeometryOrDurationCannotProduceInvalidSeeks() {
        for width in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 10, width: width, duration: 60), 0)
        }
        for x in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: x, width: 200, duration: 60), 0)
        }
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(VideoPlaybackPolicy.scrubbedTime(x: 10, width: 200, duration: duration), 0)
        }
    }
}
