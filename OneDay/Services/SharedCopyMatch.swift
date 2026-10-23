import Foundation

/// Recognizes the user's own upload among iCloud Shared Album copies.
/// PhotoKit exposes no contributor, so a shared copy is matched to an original
/// in the user's own library by capture time.
///
/// A copy usually keeps the original's capture second, but some copies carry a
/// whole-second time that rounds to a neighboring second (original
/// `…107.40`, copy `…108.0`). Such near matches also require the same original
/// file name, so another contributor's photo from the same moment stays theirs.
nonisolated enum SharedCopyMatch {
    static let tolerance: TimeInterval = 1

    static func captureSecond(_ time: TimeInterval) -> Int {
        Int(time.rounded())
    }

    /// `IMG_5243.HEIC` and `img_5243.jpg` share the stem `img_5243`; copies
    /// may be re-encoded, so the extension is ignored.
    static func fileStem(_ name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }

    /// Indices of `sortedTimes` within `tolerance` of `time`.
    static func nearbyIndices(of time: TimeInterval, in sortedTimes: [TimeInterval]) -> Range<Int> {
        let lower = firstIndex(notBelow: time - tolerance, in: sortedTimes)
        var upper = lower
        while upper < sortedTimes.count, sortedTimes[upper] <= time + tolerance { upper += 1 }
        return lower..<upper
    }

    /// File names are read lazily: only near, non-identical captures need them.
    static func isOwnCopy(
        sharedTime: TimeInterval,
        sharedNames: () -> [String],
        ownSeconds: Set<Int>,
        ownSortedTimes: [TimeInterval],
        ownNames: (Int) -> [String]
    ) -> Bool {
        if ownSeconds.contains(captureSecond(sharedTime)) { return true }
        let nearby = nearbyIndices(of: sharedTime, in: ownSortedTimes)
        guard !nearby.isEmpty else { return false }
        let stems = Set(sharedNames().map(fileStem))
        guard !stems.isEmpty else { return false }
        return nearby.contains { index in
            ownNames(index).contains { stems.contains(fileStem($0)) }
        }
    }

    private static func firstIndex(notBelow value: TimeInterval, in sorted: [TimeInterval]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
