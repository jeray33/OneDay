import Foundation

/// Metadata only selects candidates. It never proves that two videos are copies.
nonisolated enum SharedVideoDuplicatePolicy {
    static func contentMatches(digestA: String?, digestB: String?) -> Bool {
        guard let digestA, !digestA.isEmpty, let digestB else { return false }
        return digestA == digestB
    }

    struct Candidate: Sendable {
        let id: String
        let time: TimeInterval
        let duration: TimeInterval
        let width: Int
        let height: Int
        var isShared = true
    }

    static func unique<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert(id($0)).inserted }
    }

    static func compatible(_ a: Candidate, _ b: Candidate) -> Bool {
        guard a.id != b.id, a.isShared || b.isShared,
              a.time.isFinite, b.time.isFinite,
              a.duration.isFinite, b.duration.isFinite,
              a.duration > 0, b.duration > 0,
              a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        return abs(a.time - b.time) <= 1
            && abs(a.duration - b.duration) <= 0.1
            && abs(Double(a.width) / Double(a.height)
                   - Double(b.width) / Double(b.height)) <= 0.005
    }

    static func preferred(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.isShared != b.isShared { return !a.isShared }
        let lhs = Double(a.width) * Double(a.height)
        let rhs = Double(b.width) * Double(b.height)
        return lhs == rhs ? a.id < b.id : lhs > rhs
    }

    /// All members must match, not just a chain of similar neighbors.
    static func duplicateIDs(
        _ candidates: [Candidate],
        onUpdate: ((Set<String>) async -> Void)? = nil,
        matches: (Candidate, Candidate) async -> Bool
    ) async -> Set<String> {
        let sorted = unique(candidates, id: \.id).sorted(by: preferred)
        var groups: [[Candidate]] = []
        var hidden = Set<String>()
        for candidate in sorted {
            guard !Task.isCancelled else { break }
            var destination: Int?
            for index in groups.indices {
                var confirmed = true
                for member in groups[index] {
                    guard compatible(candidate, member),
                          await matches(candidate, member), !Task.isCancelled else {
                        confirmed = false
                        break
                    }
                }
                if confirmed { destination = index; break }
            }
            if let destination {
                groups[destination].append(candidate)
                hidden.insert(candidate.id)
                await onUpdate?(hidden)
            } else {
                groups.append([candidate])
            }
        }
        return hidden
    }
}
