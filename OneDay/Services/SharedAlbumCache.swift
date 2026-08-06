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
/// day open, which stalled the cover entrance. This actor computes them once,
/// shares the result across all callers (in-flight requests coalesce onto a
/// single computation), and is invalidated by `PhotoLibraryService`'s
/// `PHPhotoLibraryChangeObserver` when the library changes.
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
    private var inFlight: Task<Snapshot, Never>?

    /// Returns the cached snapshot, computing it (once) if necessary.
    /// Concurrent callers await the same in-flight computation.
    func current() async -> Snapshot {
        if let snapshot { return snapshot }
        if let inFlight { return await inFlight.value }
        let task = Task.detached(priority: .userInitiated) { Self.compute() }
        inFlight = task
        let result = await task.value
        snapshot = result
        inFlight = nil
        return result
    }

    /// Precomputes the snapshot off the critical path (e.g. during tunnel
    /// preparation) so the first `items(on:)` after landing does not stall.
    func warm() async {
        _ = await current()
    }

    /// Drops the cached snapshot so the next access recomputes it. Called when
    /// the photo library changes.
    func invalidate() {
        snapshot = nil
        inFlight = nil
    }

    // MARK: - Computation

    /// Short-circuits when the user has no shared albums: the whole shared merge
    /// (and the expensive own-library scan) is skipped entirely.
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
/// inherit `NSObject`. Invalidates the shared-album cache on any change.
final class SharedAlbumLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = SharedAlbumLibraryObserver()
    private override init() { super.init() }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { await SharedAlbumCache.shared.invalidate() }
    }
}
