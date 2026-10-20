import Foundation

nonisolated struct TunnelCandidateDay: Sendable {
    let date: Date
    let assetIdentifiers: [String]
    let previewCount: Int
}

nonisolated struct TunnelDaySelection: Equatable, Sendable {
    let date: Date
    let assetIdentifiers: [String]
}

/// Session-stable sampling. Candidates arrive in a once-shuffled priority order.
nonisolated enum TunnelSelectionPlanner {
    static func select(
        from candidates: [TunnelCandidateDay],
        preserving previous: [TunnelDaySelection],
        minimumCount: Int,
        maximumDays: Int,
        newestFirst: Bool
    ) -> [TunnelDaySelection] {
        guard maximumDays > 0,
              let anchor = candidates.filter({ !$0.assetIdentifiers.isEmpty }).max(by: { $0.date < $1.date })
        else { return [] }
        let eligible = candidates.filter {
            $0.date == anchor.date || $0.assetIdentifiers.count >= minimumCount
        }
        let byDate = Dictionary(uniqueKeysWithValues: eligible.map { ($0.date, $0) })
        let oldByDate = Dictionary(uniqueKeysWithValues: previous.map { ($0.date, $0) })
        let oldRest = previous.filter { $0.date != anchor.date }
        let retained = Set(oldRest.prefix(maximumDays - 1).compactMap {
            byDate[$0.date] == nil ? nil : $0.date
        })
        var replacements = eligible.map(\.date).filter {
            $0 != anchor.date && !retained.contains($0)
        }.makeIterator()
        var dates: [Date] = []
        for old in oldRest.prefix(maximumDays - 1) {
            if byDate[old.date] != nil {
                dates.append(old.date)
            } else if let replacement = replacements.next() {
                dates.append(replacement)
            }
        }
        while dates.count < maximumDays - 1, let replacement = replacements.next() {
            dates.append(replacement)
        }
        if newestFirst { dates.sort(by: >) }
        return ([anchor.date] + dates).compactMap { date in
            guard let day = byDate[date] else { return nil }
            let available = Set(day.assetIdentifiers)
            let kept = (oldByDate[date]?.assetIdentifiers ?? []).filter { available.contains($0) }
            let keptIDs = Set(kept)
            let filled = kept + day.assetIdentifiers.filter { !keptIDs.contains($0) }
            return TunnelDaySelection(date: date, assetIdentifiers: Array(filled.prefix(day.previewCount)))
        }
    }

    /// Preserve the focused date and its fractional travel offset when slots move.
    static func remapProgress(
        _ progress: Double, oldDates: [Date], newDates: [Date], spacing: Double, focal: Double = 1
    ) -> Double {
        guard !newDates.isEmpty, spacing > 0 else { return -focal }
        let end = Double(newDates.count - 1) * spacing - focal
        guard !oldDates.isEmpty else { return min(max(progress, -focal), end) }
        let oldIndex = min(max(Int(((progress + focal) / spacing).rounded()), 0), oldDates.count - 1)
        let offset = progress - (Double(oldIndex) * spacing - focal)
        let newIndex: Int
        if let exact = newDates.firstIndex(of: oldDates[oldIndex]) {
            newIndex = exact
        } else {
            // Prefer a surviving old neighbour; otherwise keep the same slot.
            let neighbours = oldDates.indices.sorted {
                let left = abs($0 - oldIndex)
                let right = abs($1 - oldIndex)
                return left == right ? $0 > $1 : left < right
            }
            newIndex = neighbours.compactMap { newDates.firstIndex(of: oldDates[$0]) }.first
                ?? min(oldIndex, newDates.count - 1)
        }
        return min(max(Double(newIndex) * spacing - focal + offset, -focal), end)
    }
}
