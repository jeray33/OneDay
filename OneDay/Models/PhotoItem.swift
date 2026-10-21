import Photos
import CoreLocation

struct PhotoItem: Identifiable, Hashable {
    let asset: PHAsset
    var caption: String? = nil
    /// Set to `true` when this asset lives in an iCloud Shared Photo Library
    /// but was contributed by another participant (heuristic on
    /// `PHAsset.sourceType`). Drives the in-app "shared" badge and the
    /// `includeSharedAlbums` filter. Populated by `PhotoItem.build(from:)`.
    var isFromSharedLibrary: Bool = false

    /// Set to `true` when this shared-album photo's capture timestamp matches
    /// an asset in the user's own library, i.e. it is almost certainly a photo
    /// the user contributed themselves rather than one a family member/friend
    /// shared. Used by the contributor-match filter to hide the user's own
    /// uploads (and their duplicate badge). Populated by `PhotoItem.build(from:)`.
    var isOwnSharedContribution: Bool = false

    /// Explicit initializer that requires the shared-library flag to be set
    /// at construction. Forces every caller to use `PhotoItem.build(from:)`
    /// so no `PhotoItem` is ever silently left with `isFromSharedLibrary=false`.
    init(asset: PHAsset, isFromSharedLibrary: Bool, isOwnSharedContribution: Bool = false) {
        self.asset = asset
        self.isFromSharedLibrary = isFromSharedLibrary
        self.isOwnSharedContribution = isOwnSharedContribution
    }

    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    var isLivePhoto: Bool { asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive) }
    var duration: TimeInterval { asset.duration }
    var creationDate: Date? { asset.creationDate }
    var location: CLLocation? { asset.location }
    var burstIdentifier: String? { asset.burstIdentifier }

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

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
