import Photos
import CoreLocation

struct PhotoItem: Identifiable, Hashable {
    let asset: PHAsset

    var id: String { asset.localIdentifier }
    var isVideo: Bool { asset.mediaType == .video }
    var duration: TimeInterval { asset.duration }
    var creationDate: Date? { asset.creationDate }
    var location: CLLocation? { asset.location }
    var burstIdentifier: String? { asset.burstIdentifier }

    var aspectRatio: CGFloat {
        guard asset.pixelHeight > 0 else { return 1 }
        return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
    }

    var isFavorite: Bool { asset.isFavorite }

    var durationText: String? {
        guard isVideo, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
