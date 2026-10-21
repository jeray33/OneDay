import Foundation

/// One automatic playback per visit, not per appearance or eligibility change.
nonisolated struct LivePhotoPlaybackPolicy {
    enum Source {
        case automatic
        case manual

        var isMuted: Bool { self == .automatic }
    }

    private(set) var isSelected = false
    private(set) var hasPlayed = false
    private var visitID: UUID?

    mutating func select(_ selected: Bool, visitID: UUID? = nil) {
        if selected != isSelected || self.visitID != visitID {
            hasPlayed = false
        }
        self.visitID = visitID
        isSelected = selected
    }

    mutating func begin(_ source: Source, ready: Bool, permitted: Bool) -> Bool {
        guard isSelected, ready, permitted else { return false }
        if source == .automatic, hasPlayed { return false }
        hasPlayed = true
        return true
    }
}
