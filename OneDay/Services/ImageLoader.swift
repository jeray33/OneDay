import Photos
import UIKit
import AVFoundation
import Foundation

nonisolated final class ImageLoader: @unchecked Sendable {
    enum LoadQuality: String {
        case fast
        case opportunistic
        case highQuality
    }

    enum LoadPriority {
        case userInitiated
        case normal
        case background

        fileprivate var taskPriority: TaskPriority {
            switch self {
            case .userInitiated: return .userInitiated
            case .normal: return .utility
            case .background: return .background
            }
        }
    }

    struct LoadStage {
        let size: CGSize
        let quality: LoadQuality
        let priority: LoadPriority

        init(size: CGSize,
             quality: LoadQuality,
             priority: LoadPriority = .normal) {
            self.size = size
            self.quality = quality
            self.priority = priority
        }
    }

    struct StageResult {
        let stage: LoadStage
        let images: [UIImage?]
    }

    private final class PendingRequest {
        var requestID: PHImageRequestID?
        var completions: [UUID: (UIImage?) -> Void]

        init(token: UUID, completion: @escaping (UIImage?) -> Void) {
            completions = [token: completion]
        }
    }

    static let shared = ImageLoader()
    private let manager = PHCachingImageManager()
    private let memoryCache = NSCache<NSString, UIImage>()
    private let requestLock = NSLock()
    private var pendingRequests: [String: PendingRequest] = [:]

    private init() {
        memoryCache.totalCostLimit = 96 * 1024 * 1024
        memoryCache.countLimit = 240
    }

    func stream(asset: PHAsset,
                targetSize: CGSize,
                contentMode: PHImageContentMode = .aspectFill,
                highQuality: Bool = false) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let quality: LoadQuality = highQuality ? .highQuality : .opportunistic
            let key = requestKey(asset: asset,
                                 targetSize: targetSize,
                                 contentMode: contentMode,
                                 quality: quality,
                                 allowsNetworkAccess: true)
            if let cached = memoryCache.object(forKey: key as NSString) {
                continuation.yield(cached)
                continuation.finish()
                return
            }

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
                if let image, !isDegraded {
                    self.store(image, forKey: key)
                }
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
    /// Pass `highQuality: true` when the image is scaled up on screen (e.g. the
    /// tunnel rewind), so it stays sharp instead of pixelating.
    func thumbnail(asset: PHAsset, size: CGSize, highQuality: Bool = false,
                   contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        let quality: LoadQuality = highQuality ? .highQuality : .fast
        return await requestImage(asset: asset,
                                  targetSize: pixelSize(for: size),
                                  contentMode: contentMode,
                                  quality: quality,
                                  allowsNetworkAccess: true)
    }

    /// Loads a bounded batch while preserving the input order. Exact duplicate
    /// requests share one PhotoKit request and every waiter remains cancellable.
    func thumbnails(assets: [PHAsset],
                    size: CGSize,
                    quality: LoadQuality = .fast,
                    priority: LoadPriority = .normal,
                    allowsNetworkAccess: Bool = true,
                    maxConcurrent: Int = 6) async -> [UIImage?] {
        guard !assets.isEmpty else { return [] }
        var images = [UIImage?](repeating: nil, count: assets.count)
        let concurrency = max(1, maxConcurrent)

        for start in stride(from: 0, to: assets.count, by: concurrency) {
            guard !Task.isCancelled else { break }
            let end = min(start + concurrency, assets.count)
            await withTaskGroup(of: (Int, UIImage?).self) { group in
                for index in start..<end {
                    group.addTask(priority: priority.taskPriority) {
                        let image = await self.requestImage(
                            asset: assets[index],
                            targetSize: self.pixelSize(for: size),
                            contentMode: .aspectFill,
                            quality: quality,
                            allowsNetworkAccess: allowsNetworkAccess
                        )
                        return (index, image)
                    }
                }
                for await (index, image) in group {
                    images[index] = image
                }
            }
        }
        return images
    }

    /// Runs ordered image stages (for example fast preview, then high quality).
    /// Ending iteration or cancelling the parent task cancels outstanding work.
    func stagedThumbnails(assets: [PHAsset],
                          stages: [LoadStage],
                          allowsNetworkAccess: Bool = true,
                          maxConcurrent: Int = 6) -> AsyncStream<StageResult> {
        AsyncStream { continuation in
            let task = Task {
                for stage in stages {
                    guard !Task.isCancelled else { break }
                    let images = await self.thumbnails(
                        assets: assets,
                        size: stage.size,
                        quality: stage.quality,
                        priority: stage.priority,
                        allowsNetworkAccess: allowsNetworkAccess,
                        maxConcurrent: maxConcurrent
                    )
                    guard !Task.isCancelled else { break }
                    continuation.yield(StageResult(stage: stage, images: images))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func playerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - Shared request coordination

    private func requestImage(asset: PHAsset,
                              targetSize: CGSize,
                              contentMode: PHImageContentMode,
                              quality: LoadQuality,
                              allowsNetworkAccess: Bool) async -> UIImage? {
        let key = requestKey(asset: asset,
                             targetSize: targetSize,
                             contentMode: contentMode,
                             quality: quality,
                             allowsNetworkAccess: allowsNetworkAccess)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerRequest(asset: asset,
                                targetSize: targetSize,
                                contentMode: contentMode,
                                quality: quality,
                                allowsNetworkAccess: allowsNetworkAccess,
                                key: key,
                                token: token) { image in
                    continuation.resume(returning: image)
                }
                if Task.isCancelled {
                    cancelRequest(key: key, token: token)
                }
            }
        } onCancel: {
            self.cancelRequest(key: key, token: token)
        }
    }

    private func registerRequest(asset: PHAsset,
                                 targetSize: CGSize,
                                 contentMode: PHImageContentMode,
                                 quality: LoadQuality,
                                 allowsNetworkAccess: Bool,
                                 key: String,
                                 token: UUID,
                                 completion: @escaping (UIImage?) -> Void) {
        requestLock.lock()
        if let cached = memoryCache.object(forKey: key as NSString) {
            requestLock.unlock()
            completion(cached)
            return
        }
        if let pending = pendingRequests[key] {
            pending.completions[token] = completion
            requestLock.unlock()
            return
        }
        pendingRequests[key] = PendingRequest(token: token, completion: completion)
        requestLock.unlock()

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        switch quality {
        case .fast: options.deliveryMode = .fastFormat
        case .opportunistic: options.deliveryMode = .opportunistic
        case .highQuality: options.deliveryMode = .highQualityFormat
        }
        options.resizeMode = quality == .highQuality ? .exact : .fast
        options.isSynchronous = false

        let requestID = manager.requestImage(for: asset,
                                             targetSize: targetSize,
                                             contentMode: contentMode,
                                             options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            let fastResultReady = quality == .fast && image != nil
            if fastResultReady || !isDegraded || cancelled || failed {
                self.completeRequest(key: key, image: image)
            }
        }

        requestLock.lock()
        if let pending = pendingRequests[key] {
            pending.requestID = requestID
            requestLock.unlock()
        } else {
            requestLock.unlock()
            manager.cancelImageRequest(requestID)
        }
    }

    private func completeRequest(key: String, image: UIImage?) {
        if let image { store(image, forKey: key) }

        requestLock.lock()
        guard let pending = pendingRequests.removeValue(forKey: key) else {
            requestLock.unlock()
            return
        }
        let callbacks = Array(pending.completions.values)
        let requestID = pending.requestID
        requestLock.unlock()

        if let requestID { manager.cancelImageRequest(requestID) }
        for callback in callbacks { callback(image) }
    }

    private func cancelRequest(key: String, token: UUID) {
        requestLock.lock()
        guard let pending = pendingRequests[key],
              let callback = pending.completions.removeValue(forKey: token) else {
            requestLock.unlock()
            return
        }
        let shouldCancelUnderlying = pending.completions.isEmpty
        let requestID = pending.requestID
        if shouldCancelUnderlying { pendingRequests.removeValue(forKey: key) }
        requestLock.unlock()

        callback(nil)
        if shouldCancelUnderlying, let requestID {
            manager.cancelImageRequest(requestID)
        }
    }

    private func requestKey(asset: PHAsset,
                            targetSize: CGSize,
                            contentMode: PHImageContentMode,
                            quality: LoadQuality,
                            allowsNetworkAccess: Bool) -> String {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        return "\(asset.localIdentifier)|\(width)x\(height)|\(contentMode.rawValue)|\(quality.rawValue)|\(allowsNetworkAccess)"
    }

    private func pixelSize(for size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1) * 2,
               height: max(size.height, 1) * 2)
    }

    private func store(_ image: UIImage, forKey key: String) {
        let cost: Int
        if let cgImage = image.cgImage {
            cost = cgImage.bytesPerRow * cgImage.height
        } else {
            let width = image.size.width * image.scale
            let height = image.size.height * image.scale
            cost = Int(width * height * 4)
        }
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
