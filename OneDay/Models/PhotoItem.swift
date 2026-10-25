import Photos
import CoreLocation

nonisolated struct PhotoItem: Identifiable, Hashable {
    /// How the asset reached this device out of a shared space.
    enum SharedSource: Hashable {
        /// Lives in an iCloud Shared Album (membership comes from the actual
        /// shared collections, so it is definitive).
        case album
        /// Matches the iCloud Shared Photo Library source-type heuristic
        /// (`.typeCloudShared` without `.typeUserLibrary`).
        case library

        /// Label shown on the preview's shared badge.
        var badgeText: String {
            switch self {
            case .album: return "共享相簿"
            case .library: return "共享图库"
            }
        }
    }

    let asset: PHAsset
    /// Capture the version with the asset snapshot. Identity alone cannot
    /// tell SwiftUI that an existing photo has been edited.
    let contentVersion: String
    var caption: String? = nil
    /// Set when this asset lives in an iCloud Shared Album or was contributed
    /// to an iCloud Shared Photo Library; `nil` for items that live only in
    /// the user's own library. Populated by `PhotoItem.build(from:)`.
    var sharedSource: SharedSource? = nil

    /// Set to `true` when this shared photo's capture timestamp matches
    /// an asset in the user's own library, i.e. it is almost certainly a photo
    /// the user contributed themselves rather than one a family member/friend
    /// shared. Used by the contributor-match filter to hide the user's own
    /// uploads (and their duplicate badge). Populated by `PhotoItem.build(from:)`.
    var isOwnSharedContribution: Bool = false

    /// The zone the capture's local date and clock time are read in (see
    /// `CaptureClock`). Set by `PhotoLibraryService.items(on:)`; the device
    /// zone elsewhere.
    var captureTimeZone: TimeZone = .current

    /// Explicit initializer that requires the shared provenance at
    /// construction. Forces every caller to use `PhotoItem.build(from:)` so
    /// no `PhotoItem` is ever silently left without its shared source.
    init(asset: PHAsset, sharedSource: SharedSource?, isOwnSharedContribution: Bool = false) {
        self.asset = asset
        self.contentVersion = asset.contentVersion
        self.sharedSource = sharedSource
        self.isOwnSharedContribution = isOwnSharedContribution
    }

    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    var isLivePhoto: Bool { asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive) }
    var duration: TimeInterval { asset.duration }
    var creationDate: Date? { asset.creationDate }
    var location: CLLocation? { asset.location }

    /// `true` for any item that came out of a shared space (album or library).
    /// Drives the in-app "shared" badge and the `includeSharedAlbums` filter.
    var isFromSharedLibrary: Bool { sharedSource != nil }

    /// `true` when someone else shared this item (not the user's own upload).
    /// Read-only handling keys off this (see `SharedAssetPolicy`).
    var isForeignShared: Bool { sharedSource != nil && !isOwnSharedContribution }

    /// Text for the preview's shared badge; `nil` when there is nothing to show.
    var sharedBadgeText: String? {
        if isOwnSharedContribution { return "我共享的" }
        return sharedSource?.badgeText
    }

    var aspectRatio: CGFloat {
        guard asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    var isFavorite: Bool { asset.isFavorite }
    var isHidden: Bool { asset.isHidden }

    var durationText: String? {
        guard isVideo, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id && lhs.contentVersion == rhs.contentVersion
            && lhs.caption == rhs.caption && lhs.sharedSource == rhs.sharedSource
            && lhs.isOwnSharedContribution == rhs.isOwnSharedContribution
            && lhs.captureTimeZone == rhs.captureTimeZone
            && lhs.isFavorite == rhs.isFavorite && lhs.isHidden == rhs.isHidden
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
