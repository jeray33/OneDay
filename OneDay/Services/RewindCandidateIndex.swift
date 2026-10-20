import Photos

/// Unfiltered PhotoKit candidates, fetched once per tunnel session.
nonisolated struct RewindCandidateIndex: @unchecked Sendable {
    let days: [TunnelCandidateDay]
    let assetsByID: [String: PHAsset]

    func plan(
        matching selection: MediaCategorySelection,
        preserving previous: [TunnelDaySelection],
        minimumCount: Int, maximumDays: Int, newestFirst: Bool
    ) async -> [TunnelDaySelection] {
        let selection = selection.includingPrimary
        return await Task.detached(priority: .userInitiated) {
            let filtered = days.map { day in
                TunnelCandidateDay(
                    date: day.date,
                    assetIdentifiers: day.assetIdentifiers.filter {
                        guard let asset = assetsByID[$0] else { return false }
                        return selection.includes(asset)
                    },
                    previewCount: day.previewCount
                )
            }
            return TunnelSelectionPlanner.select(
                from: filtered, preserving: previous, minimumCount: minimumCount,
                maximumDays: maximumDays, newestFirst: newestFirst
            )
        }.value
    }

    func groups(for plan: [TunnelDaySelection]) -> [(date: Date, assets: [PHAsset])] {
        plan.map { day in (day.date, day.assetIdentifiers.compactMap { assetsByID[$0] }) }
    }
}
