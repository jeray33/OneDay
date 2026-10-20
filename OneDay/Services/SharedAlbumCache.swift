import Foundation
import Photos

/// Session-level cache for the library-wide data needed to merge and tag
/// iCloud Shared Album photos.
///
/// Two computations are involved and both are library-wide (independent of any
/// specific day), so they are the same for every `items(on:)` / `eligibleDays()`
/// / `todayInHistory()` call within a session:
/// - `sharedAlbumAssets()` — every asset in the user's shared albums.
/// - `ownLibraryCreationSeconds()` — capture seconds of the user's own library,
///   used to tell the user's own uploads apart from photos shared by others.
///
/// Previously both ran inside `items(on:)`, i.e. a full-library scan on every
/// day open, which stalled the cover entrance. This actor computes them once
/// and shares the result across all callers. To keep even the first computation
/// off the critical path it loads in two phases (cheap shared-membership first,
/// then the own-library scan in the background) and, on library changes
/// (via `PhotoLibraryService`'s `PHPhotoLibraryChangeObserver`), keeps serving
/// the current snapshot while a debounced background refresh recomputes it
/// (stale-while-revalidate).
actor SharedAlbumCache {
    static let shared = SharedAlbumCache()

    /// Immutable, library-wide shared-album facts. `PHAsset` is safe to read
    /// from any thread; the array is never mutated after construction.
    struct Snapshot: @unchecked Sendable {
        /// Every asset that lives in an iCloud Shared Album.
        let sharedAssets: [PHAsset]
        /// `localIdentifier`s of `sharedAssets` (the shared-tag set).
        let sharedAssetIDs: Set<String>
        /// Subset of `sharedAssetIDs` whose capture second matches the user's
        /// own library, i.e. photos the user contributed themselves.
        let ownContributionIDs: Set<String>

        /// Shared assets contributed by others (everything that is not the
        /// user's own upload). Mirrors the old
        /// `PhotoLibraryService.foreignSharedAlbumAssets(ownSeconds:)`.
        var foreignSharedAssets: [PHAsset] {
            sharedAssets.filter { !ownContributionIDs.contains($0.localIdentifier) }
        }

        static let empty = Snapshot(sharedAssets: [], sharedAssetIDs: [], ownContributionIDs: [])
    }

    private var snapshot: Snapshot?
    private var loadTask: Task<Snapshot, Never>?
    private var isRefreshing = false
    private var debounceTask: Task<Void, Never>?

    /// How long the library must stay quiet after a change before we recompute.
    /// During active iCloud sync changes arrive in a continuous trickle; without
    /// this the refresh would loop nonstop, each pass paying a multi-second
    /// full-library scan.
    private static let refreshQuietPeriod: UInt64 = 8_000_000_000 // 8s

    /// Returns the cached snapshot, computing it only when there is nothing to
    /// serve yet (the first call of the session). Once a snapshot exists this
    /// returns instantly, even while a background refresh is in flight — the
    /// data is at most a few seconds stale, which is fine for a badge.
    /// Concurrent first callers coalesce onto the same computation.
    ///
    /// The first computation is two-phase to keep it off the critical path:
    /// phase 1 fetches only shared-album membership (fast, a few hundred ms) and
    /// is returned immediately; phase 2 runs the multi-second own-library scan
    /// in the background and swaps in the complete snapshot (with contributor
    /// matching) via `triggerFullRefresh`. Until phase 2 lands, every shared
    /// photo is shown and badged (no one is hidden as "my own"); the badges then
    /// refine a moment later.
    func current() async -> Snapshot {
        if let snapshot { return snapshot }
        if let loadTask { return await loadTask.value }
        let task = Task.detached(priority: .userInitiated) { Self.computeSharedOnly() }
        loadTask = task
        let base = await task.value
        snapshot = base
        loadTask = nil
        triggerFullRefresh() // phase 2: contributor matching, off the critical path
        return base
    }

    /// Precomputes the snapshot off the critical path (e.g. during tunnel
    /// preparation) so the first `items(on:)` after landing does not stall.
    func warm() async {
        _ = await current()
    }

    /// The photo library changed. Instead of dropping the snapshot (which would
    /// force the next access to pay the multi-second cold recompute — the cause
    /// of the cover-entrance stall during active iCloud sync), keep serving the
    /// current snapshot and recompute in the background, swapping in the fresh
    /// result when ready. Rapid change bursts collapse into a single trailing
    /// refresh.
    func markStale() {
        guard snapshot != nil else { return } // nothing to keep; next current() computes
        // Debounce: (re)start the quiet-period timer on every change so a burst
        // of sync notifications collapses into a single refresh once the
        // library settles.
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshQuietPeriod)
            guard !Task.isCancelled else { return }
            await self?.triggerFullRefresh()
        }
    }

    /// Recomputes the complete snapshot (shared membership + the own-library
    /// scan for contributor matching) in the background and swaps it in. Used
    /// both for phase 2 of the first load and for library-change refreshes.
    /// Coalesces: a refresh already in flight is not duplicated.
    private func triggerFullRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let fresh = await Task.detached(priority: .utility) { Self.compute() }.value
            snapshot = fresh
            isRefreshing = false
            // Notify after the debounced snapshot is ready, not on classification
            // or each intermediate PhotoKit change during iCloud synchronization.
            NotificationCenter.default.post(name: .photoLibraryContentChanged, object: nil)
        }
    }

    // MARK: - Computation

    /// Phase 1: shared-album membership only, with `ownContributionIDs` left
    /// empty. Cheap (no own-library scan) so the first `current()` returns
    /// quickly; contributor matching is filled in afterwards by `compute()`.
    nonisolated static func computeSharedOnly() -> Snapshot {
        let sharedAssets = PhotoLibraryService.sharedAlbumAssets()
        guard !sharedAssets.isEmpty else { return .empty }
        return Snapshot(
            sharedAssets: sharedAssets,
            sharedAssetIDs: Set(sharedAssets.map(\.localIdentifier)),
            ownContributionIDs: []
        )
    }

    /// Full snapshot: shared membership plus the own-library scan that
    /// distinguishes the user's own uploads. Short-circuits when the user has no
    /// shared albums, skipping the expensive scan entirely.
    nonisolated static func compute() -> Snapshot {
        let sharedAssets = PhotoLibraryService.sharedAlbumAssets()
        guard !sharedAssets.isEmpty else { return .empty }

        let ownSeconds = PhotoLibraryService.ownLibraryCreationSeconds()
        let sharedAssetIDs = Set(sharedAssets.map(\.localIdentifier))
        var ownContributionIDs = Set<String>()
        for asset in sharedAssets {
            if let date = asset.creationDate,
               ownSeconds.contains(Int(date.timeIntervalSince1970.rounded())) {
                ownContributionIDs.insert(asset.localIdentifier)
            }
        }
        return Snapshot(
            sharedAssets: sharedAssets,
            sharedAssetIDs: sharedAssetIDs,
            ownContributionIDs: ownContributionIDs
        )
    }
}

/// Lightweight `NSObject` adapter so we can observe photo-library changes
/// without forcing `PhotoLibraryService` (a plain actor-isolated class) to
/// inherit `NSObject`. Marks the shared-album cache stale (background refresh)
/// on any change.
final class SharedAlbumLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = SharedAlbumLibraryObserver()
    private override init() { super.init() }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { await SharedAlbumCache.shared.markStale() }
        Task { await OtherImageClassificationService.shared.libraryDidChange() }
    }
}
