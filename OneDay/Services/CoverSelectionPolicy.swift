import Foundation

nonisolated enum CoverSelectionPolicy {
    static func sampleIndices(count: Int, limit: Int = 24) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        let size = min(count, limit)
        guard size > 1 else { return [0] }
        return (0..<size).map { $0 * (count - 1) / (size - 1) }
    }

    /// Missing local images never block selection; chronological order is the
    /// deterministic fallback, including when the deadline yields no scores.
    static func rankedIndices(scores: [Int: Double], count: Int, top: Int) -> [Int] {
        guard count > 0, top > 0 else { return [] }
        let ranked = scores.keys.filter { (0..<count).contains($0) && scores[$0]!.isFinite }
            .sorted {
                let a = scores[$0]!, b = scores[$1]!
                return a == b ? $0 < $1 : a > b
            }
        let scored = Set(ranked)
        return Array((ranked + (0..<count).filter { !scored.contains($0) }).prefix(top))
    }
}
