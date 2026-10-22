import Photos
import Foundation

extension PHAsset {
    /// Identity stays stable across edits; content consumers must not key on
    /// localIdentifier alone. Dimensions also cover early Photos notifications.
    nonisolated var contentVersion: String {
        "\(localIdentifier)|\(modificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(pixelWidth)x\(pixelHeight)"
    }
}
