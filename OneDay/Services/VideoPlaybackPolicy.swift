import Foundation

/// Playback intent is independent of buffering and of the video's zoom level.
nonisolated struct VideoPlaybackPolicy {
    private(set) var isPermitted = false
    private(set) var isPlaying = false
    private(set) var isScrubbing = false
    private(set) var revision: UInt = 0
    private var resumesAfterScrubbing = false

    mutating func permit(_ permitted: Bool) {
        isPermitted = permitted
        if !permitted { pause() }
    }

    @discardableResult
    mutating func play(ready: Bool) -> Bool {
        guard isPermitted, ready, !isScrubbing else { return false }
        revision &+= 1
        isPlaying = true
        return true
    }

    mutating func pause() {
        revision &+= 1
        isPlaying = false
        isScrubbing = false
        resumesAfterScrubbing = false
    }

    @discardableResult
    mutating func beginScrubbing(ready: Bool) -> Bool {
        guard isPermitted, ready, !isScrubbing else { return false }
        revision &+= 1
        resumesAfterScrubbing = isPlaying
        isPlaying = false
        isScrubbing = true
        return true
    }

    mutating func endScrubbing() -> Bool {
        guard isScrubbing else { return false }
        let resume = resumesAfterScrubbing && isPermitted
        isScrubbing = false
        resumesAfterScrubbing = false
        return resume
    }

    func canResumeSeek(revision: UInt) -> Bool {
        isPermitted && !isScrubbing && self.revision == revision
    }

    static func validDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }

    static func clampedTime(_ seconds: Double, duration: Double) -> Double {
        let duration = validDuration(duration)
        guard seconds.isFinite else { return 0 }
        return min(max(0, seconds), duration)
    }

    static func progress(position: Double, duration: Double) -> Double {
        let duration = validDuration(duration)
        guard duration > 0 else { return 0 }
        return clampedTime(position, duration: duration) / duration
    }

    static func scrubbedTime(x: Double, width: Double, duration: Double) -> Double {
        guard x.isFinite, width.isFinite, width > 0 else { return 0 }
        return min(max(x / width, 0), 1) * validDuration(duration)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(max(0, seconds), Double(Int.max / 2))) : 0
        if value >= 3600 {
            return String(format: "%ld:%02ld:%02ld", value / 3600, (value / 60) % 60, value % 60)
        }
        return String(format: "%02ld:%02ld", value / 60, value % 60)
    }
}
