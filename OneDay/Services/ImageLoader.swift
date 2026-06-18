import Photos
import UIKit
import AVFoundation

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    nonisolated(unsafe) private let manager = PHCachingImageManager()
    private init() {}

    nonisolated func stream(asset: PHAsset,
                            targetSize: CGSize,
                            contentMode: PHImageContentMode = .aspectFill,
                            highQuality: Bool = false) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
            options.resizeMode = .fast
            let requestID = manager.requestImage(for: asset,
                                                 targetSize: targetSize,
                                                 contentMode: contentMode,
                                                 options: options) { image, info in
                if let image { continuation.yield(image) }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                if !isDegraded || cancelled || failed {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.manager.cancelImageRequest(requestID)
            }
        }
    }

    /// Single-shot thumbnail, suitable for preloading the rewind flash pool.
    nonisolated func thumbnail(asset: PHAsset, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isSynchronous = false
            let target = CGSize(width: size.width * 2, height: size.height * 2)
            var resumed = false
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: options) { image, _ in
                if !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    nonisolated func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
