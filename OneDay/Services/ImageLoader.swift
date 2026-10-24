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
        let contentMode: PHImageContentMode

        init(size: CGSize,
             quality: LoadQuality,
             priority: LoadPriority = .normal,
             contentMode: PHImageContentMode = .aspectFill) {
            self.size = size
            self.quality = quality
            self.priority = priority
            self.contentMode = contentMode
        }
    }

    struct StageResult {
        let stage: LoadStage
        let images: [UIImage?]
    }

    // MARK: - Request bookkeeping

    /// One single-shot PhotoKit request shared by identical waiters.
    private final class PendingRequest {
        var requestID: PHImageRequestID?
        let asset: PHAsset
        let targetSize: CGSize
        let contentMode: PHImageContentMode
        var completions: [UUID: (UIImage?) -> Void]

        init(asset: PHAsset,
             targetSize: CGSize,
             contentMode: PHImageContentMode,
             token: UUID,
             completion: @escaping (UIImage?) -> Void) {
            self.asset = asset
            self.targetSize = targetSize
            self.contentMode = contentMode
            completions = [token: completion]
        }
    }

    /// One streaming PhotoKit request shared by any number of consumers.
    /// Every delivered frame reaches every live continuation; the underlying
    /// request is cancelled only when the last consumer goes away.
    private final class StreamRequest {
        var requestID: PHImageRequestID?
        var continuations: [UUID: AsyncStream<UIImage>.Continuation] = [:]
    }

    /// Bookkeeping for one cached image, so the best cached version of an
    /// asset can be found without probing keys for every size.
    private struct AssetIndexEntry {
        let key: String
        let contentVersion: String
        let mode: PHImageContentMode
        let pixelArea: Int
    }

    static let shared = ImageLoader()
    private let manager = PHCachingImageManager()

    // Tiered caches. Analysis samples, grid thumbnails and full-quality
    // previews have very different footprints; one shared cache let small
    // samples evict the images the user was actually looking at (and vice
    // versa), thrashing during scrolls.
    private let smallCache = NSCache<NSString, UIImage>()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let largeCache = NSCache<NSString, UIImage>()

    private let requestLock = NSLock()
    private var pendingRequests: [String: PendingRequest] = [:]
    private var streamRequests: [String: StreamRequest] = [:]
    private var assetIndex: [String: [AssetIndexEntry]] = [:]

    private init() {
        smallCache.countLimit = 256
        smallCache.totalCostLimit = 32 * 1024 * 1024
        thumbnailCache.countLimit = 700
        thumbnailCache.totalCostLimit = 128 * 1024 * 1024
        largeCache.countLimit = 16
        largeCache.totalCostLimit = 192 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Preview-sized images are the most expensive to hold and the
            // cheapest to reload; drop them first.
            self?.largeCache.removeAllObjects()
        }
    }

    // MARK: - Streams

    /// Delivers best-available frames for `asset`.
    ///
    /// - `highQuality` requests only the final, exact frame.
    /// - `progressive` first streams opportunistic frames (a cheap degraded
    ///   pass, then the full-size fast resize) and follows with one
    ///   exact-size high-quality frame when the fast pass fell short of the
    ///   target, typically for iCloud originals. `highQuality` is ignored
    ///   when `progressive` is set.
    ///
    /// Identical concurrent requests share a single PhotoKit call, and
    /// cached results are delivered synchronously.
    func stream(asset: PHAsset,
                targetSize: CGSize,
                contentMode: PHImageContentMode = .aspectFill,
                highQuality: Bool = false,
                progressive: Bool = false) -> AsyncStream<UIImage> {
        if progressive {
            return progressiveStream(asset: asset, targetSize: targetSize,
                                     contentMode: contentMode)
        }
        return sharedStream(asset: asset, targetSize: targetSize,
                            contentMode: contentMode,
                            quality: highQuality ? .highQuality : .opportunistic,
                            allowsNetworkAccess: true)
    }

    private func progressiveStream(asset: PHAsset,
                                   targetSize: CGSize,
                                   contentMode: PHImageContentMode) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let task = Task {
                var lastFrame: UIImage?
                for await frame in self.sharedStream(
                    asset: asset, targetSize: targetSize, contentMode: contentMode,
                    quality: .opportunistic, allowsNetworkAccess: true
                ) {
                    lastFrame = frame
                    continuation.yield(frame)
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                // The fast pass usually already covers the target for local
                // photos; only chase the exact resize when it fell short.
                let expected = Self.expectedSize(forAsset: asset,
                                                 targetSize: targetSize,
                                                 contentMode: contentMode)
                let fastPassComplete = lastFrame.map { Self.frame($0, covers: expected) } ?? false
                if !fastPassComplete,
                   let sharp = await self.requestImage(
                    asset: asset, targetSize: targetSize, contentMode: contentMode,
                    quality: .highQuality, allowsNetworkAccess: true) {
                    continuation.yield(sharp)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func sharedStream(asset: PHAsset,
                              targetSize: CGSize,
                              contentMode: PHImageContentMode,
                              quality: LoadQuality,
                              allowsNetworkAccess: Bool) -> AsyncStream<UIImage> {
        let key = requestKey(asset: asset, targetSize: targetSize,
                             contentMode: contentMode, quality: quality,
                             allowsNetworkAccess: allowsNetworkAccess)
        if let cached = cachedImage(forKey: key) {
            return AsyncStream { continuation in
                continuation.yield(cached)
                continuation.finish()
            }
        }
        let token = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.detachStreamConsumer(key: key, token: token)
            }
            self.attachStreamConsumer(
                key: key, token: token, continuation: continuation, asset: asset,
                targetSize: targetSize, contentMode: contentMode,
                quality: quality, allowsNetworkAccess: allowsNetworkAccess)
        }
    }

    private func attachStreamConsumer(key: String,
                                      token: UUID,
                                      continuation: AsyncStream<UIImage>.Continuation,
                                      asset: PHAsset,
                                      targetSize: CGSize,
                                      contentMode: PHImageContentMode,
                                      quality: LoadQuality,
                                      allowsNetworkAccess: Bool) {
        requestLock.lock()
        if let cached = cachedImage(forKey: key) {
            requestLock.unlock()
            continuation.yield(cached)
            continuation.finish()
            return
        }
        if let existing = streamRequests[key] {
            existing.continuations[token] = continuation
            requestLock.unlock()
            return
        }
        let entry = StreamRequest()
        entry.continuations[token] = continuation
        streamRequests[key] = entry
        requestLock.unlock()

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.deliveryMode = deliveryMode(for: quality)
        options.resizeMode = quality == .highQuality ? .exact : .fast
        options.isSynchronous = false
        let requestID = manager.requestImage(
            for: asset, targetSize: targetSize, contentMode: contentMode, options: options
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let failed = info?[PHImageErrorKey] != nil
            let finished = !isDegraded || cancelled || failed
            let storeable = image != nil && finished && !cancelled && !failed
            self.deliverStreamResult(
                key: key, image: image, finished: finished, storeable: storeable,
                asset: asset, targetSize: targetSize, contentMode: contentMode)
        }
        requestLock.lock()
        if let entry = streamRequests[key] {
            entry.requestID = requestID
            requestLock.unlock()
        } else {
            requestLock.unlock()
            manager.cancelImageRequest(requestID)
        }
    }

    /// Delivers one PhotoKit callback to every live consumer of the request.
    private func deliverStreamResult(key: String,
                                     image: UIImage?,
                                     finished: Bool,
                                     storeable: Bool,
                                     asset: PHAsset,
                                     targetSize: CGSize,
                                     contentMode: PHImageContentMode) {
        if storeable, let image {
            store(image, forKey: key, asset: asset, targetSize: targetSize,
                  contentMode: contentMode)
        }
        requestLock.lock()
        guard let entry = streamRequests[key] else {
            requestLock.unlock()
            return
        }
        let continuations = Array(entry.continuations.values)
        if finished {
            streamRequests.removeValue(forKey: key)
        }
        requestLock.unlock()
        for continuation in continuations {
            if let image { continuation.yield(image) }
            if finished { continuation.finish() }
        }
    }

    /// One consumer went away. The shared request is cancelled only when it
    /// was the last one.
    private func detachStreamConsumer(key: String, token: UUID) {
        requestLock.lock()
        guard let entry = streamRequests[key] else {
            requestLock.unlock()
            return
        }
        entry.continuations.removeValue(forKey: token)
        if entry.continuations.isEmpty {
            let requestID = entry.requestID
            streamRequests.removeValue(forKey: key)
            requestLock.unlock()
            if let requestID { manager.cancelImageRequest(requestID) }
        } else {
            requestLock.unlock()
        }
    }

    // MARK: - Single-shot thumbnails

    /// Single-shot thumbnail for photo-derived colors and preview images.
    /// Pass `highQuality: true` when the image is scaled up on screen (e.g. the
    /// tunnel rewind), so it stays sharp instead of pixelating.
    func thumbnail(asset: PHAsset, size: CGSize, highQuality: Bool = false,
                   contentMode: PHImageContentMode = .aspectFill,
                   allowsNetworkAccess: Bool = true) async -> UIImage? {
        let quality: LoadQuality = highQuality ? .highQuality : .fast
        return await requestImage(asset: asset,
                                  targetSize: pixelSize(for: size,
                                                        asset: asset,
                                                        contentMode: contentMode),
                                  contentMode: contentMode,
                                  quality: quality,
                                  allowsNetworkAccess: allowsNetworkAccess)
    }

    /// High-quality frame at an exact pixel target. Mirrors the preview
    /// page's progressive-stream second stage, so both share one cache entry.
    func previewFrame(asset: PHAsset, targetPixelSize: CGSize) async -> UIImage? {
        await requestImage(asset: asset,
                           targetSize: targetPixelSize,
                           contentMode: .aspectFit,
                           quality: .highQuality,
                           allowsNetworkAccess: true)
    }

    /// Loads a bounded batch while preserving the input order. Exact duplicate
    /// requests share one PhotoKit request and every waiter remains cancellable.
    func thumbnails(assets: [PHAsset],
                    size: CGSize,
                    quality: LoadQuality = .fast,
                    priority: LoadPriority = .normal,
                    contentMode: PHImageContentMode = .aspectFill,
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
                            targetSize: self.pixelSize(for: size,
                                                       asset: assets[index],
                                                       contentMode: contentMode),
                            contentMode: contentMode,
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
                        contentMode: stage.contentMode,
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

    // MARK: - Prefetch

    /// Loads one opportunistic frame per asset with exactly the parameters a
    /// progressive stream's first stage uses, so later streams hit the memory
    /// cache. Warms the photos surrounding the one being previewed. (The
    /// caching manager's own `startCachingImages` cannot match per-asset
    /// aspect-fit target sizes, so warming goes through the shared loader.)
    func preload(assets: [PHAsset], targetSize: CGSize,
                 contentMode: PHImageContentMode = .aspectFit) async {
        guard !assets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for asset in assets {
                group.addTask(priority: .utility) {
                    _ = await self.requestImage(
                        asset: asset, targetSize: targetSize, contentMode: contentMode,
                        quality: .opportunistic, allowsNetworkAccess: true)
                }
            }
        }
    }

    // MARK: - Cached lookup

    /// The largest image already cached for this asset's current content
    /// version, or nil. Synchronous: lets a hero flight or preview start from
    /// the exact pixels the grid is showing instead of waiting for a fresh
    /// PhotoKit request. Pass a `contentMode` to prefer cached images that
    /// were requested with it (e.g. `.aspectFit` for previews).
    func bestCachedImage(for asset: PHAsset,
                         contentMode: PHImageContentMode? = nil) -> UIImage? {
        requestLock.lock()
        let entries = assetIndex[asset.localIdentifier] ?? []
        let version = asset.contentVersion
        var candidates = entries.filter { $0.contentVersion == version }
        if let contentMode {
            let preferred = candidates.filter { $0.mode == contentMode }
            if !preferred.isEmpty { candidates = preferred }
        }
        candidates.sort { $0.pixelArea > $1.pixelArea }
        let keys = candidates.map(\.key)
        requestLock.unlock()
        for key in keys {
            if let image = cachedImage(forKey: key) { return image }
        }
        return nil
    }

    // MARK: - Live photo / video

    /// Only deliver the final current-version resource. Termination cancels iCloud work too.
    func livePhotoStream(asset: PHAsset, targetSize: CGSize) -> AsyncStream<PHLivePhoto> {
        AsyncStream { continuation in
            let options = PHLivePhotoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let requestID = manager.requestLivePhoto(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { photo, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if cancelled || failed {
                    continuation.finish()
                } else if !degraded {
                    if let photo { continuation.yield(photo) }
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.manager.cancelImageRequest(requestID)
            }
        }
    }

    enum VideoEvent: @unchecked Sendable {
        case progress(Double)
        case ready(AVPlayerItem)
    }

    enum VideoLoadError: LocalizedError {
        case unavailable

        var errorDescription: String? { "无法加载此视频，请检查网络后重试。" }
    }

    /// Terminating the stream cancels PhotoKit's request, including iCloud downloads.
    func videoStream(for asset: PHAsset) -> AsyncThrowingStream<VideoEvent, Error> {
        AsyncThrowingStream { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.progressHandler = { progress, _, _, _ in
                continuation.yield(.progress(progress))
            }
            let requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.finish(throwing: CancellationError())
                } else if let item {
                    continuation.yield(.ready(item))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: VideoLoadError.unavailable)
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.manager.cancelImageRequest(requestID)
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
        if let cached = cachedImage(forKey: key) { return cached }

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
        if let cached = cachedImage(forKey: key) {
            requestLock.unlock()
            completion(cached)
            return
        }
        if let pending = pendingRequests[key] {
            pending.completions[token] = completion
            requestLock.unlock()
            return
        }
        pendingRequests[key] = PendingRequest(asset: asset,
                                              targetSize: targetSize,
                                              contentMode: contentMode,
                                              token: token,
                                              completion: completion)
        requestLock.unlock()

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.deliveryMode = deliveryMode(for: quality)
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
        requestLock.lock()
        guard let pending = pendingRequests.removeValue(forKey: key) else {
            requestLock.unlock()
            return
        }
        let callbacks = Array(pending.completions.values)
        let requestID = pending.requestID
        requestLock.unlock()

        if let image {
            store(image, forKey: key, asset: pending.asset,
                  targetSize: pending.targetSize, contentMode: pending.contentMode)
        }
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

    private func deliveryMode(for quality: LoadQuality) -> PHImageRequestOptionsDeliveryMode {
        switch quality {
        case .fast: return .fastFormat
        case .opportunistic: return .opportunistic
        case .highQuality: return .highQualityFormat
        }
    }

    // MARK: - Caches

    private enum CacheTier {
        case small      // colour/sharpness analysis samples
        case thumbnail  // grid and tunnel thumbnails
        case large      // preview and hero frames
    }

    private static func cacheTier(forPixelSize size: CGSize) -> CacheTier {
        let maxDimension = max(size.width, size.height)
        if maxDimension <= 320 { return .small }
        if maxDimension <= 1024 { return .thumbnail }
        return .large
    }

    private func cache(for tier: CacheTier) -> NSCache<NSString, UIImage> {
        switch tier {
        case .small: return smallCache
        case .thumbnail: return thumbnailCache
        case .large: return largeCache
        }
    }

    /// A key encodes the requested pixel size, so it can only ever live in
    /// one tier; probing all three keeps lookups simple and safe.
    private func cachedImage(forKey key: String) -> UIImage? {
        largeCache.object(forKey: key as NSString)
            ?? thumbnailCache.object(forKey: key as NSString)
            ?? smallCache.object(forKey: key as NSString)
    }

    private func store(_ image: UIImage,
                       forKey key: String,
                       asset: PHAsset,
                       targetSize: CGSize,
                       contentMode: PHImageContentMode) {
        let tier = Self.cacheTier(forPixelSize: targetSize)
        cache(for: tier).setObject(image, forKey: key as NSString,
                                   cost: Self.decodedCost(of: image))
        let id = asset.localIdentifier
        let entry = AssetIndexEntry(key: key,
                                    contentVersion: asset.contentVersion,
                                    mode: contentMode,
                                    pixelArea: Int(targetSize.width * targetSize.height))
        requestLock.lock()
        var entries = assetIndex[id] ?? []
        if !entries.contains(where: { $0.key == key }) {
            entries.append(entry)
            assetIndex[id] = entries
        }
        requestLock.unlock()
    }

    private static func decodedCost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        return Int(width * height * 4)
    }

    private func requestKey(asset: PHAsset,
                            targetSize: CGSize,
                            contentMode: PHImageContentMode,
                            quality: LoadQuality,
                            allowsNetworkAccess: Bool) -> String {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        // The asset identifier keeps two assets that happen to share a
        // content version from ever sharing a cache entry.
        return "\(asset.localIdentifier)|\(asset.contentVersion)|\(width)x\(height)|\(contentMode.rawValue)|\(quality.rawValue)|\(allowsNetworkAccess)"
    }

    private func pixelSize(for size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1) * 2,
               height: max(size.height, 1) * 2)
    }

    /// `.aspectFit` requests use a per-asset target whose pixels have the same
    /// aspect ratio as the original photo. This keeps thumbnails lightweight
    /// without relying on PhotoKit's sometimes square/cropped preview geometry.
    private func pixelSize(for size: CGSize,
                           asset: PHAsset,
                           contentMode: PHImageContentMode) -> CGSize {
        let bounds = pixelSize(for: size)
        guard contentMode == .aspectFit,
              asset.pixelWidth > 0,
              asset.pixelHeight > 0 else { return bounds }

        let aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        let boundsAspect = bounds.width / bounds.height
        if aspect >= boundsAspect {
            return CGSize(width: bounds.width,
                          height: max((bounds.width / aspect).rounded(.up), 1))
        }
        return CGSize(width: max((bounds.height * aspect).rounded(.up), 1),
                      height: bounds.height)
    }

    /// The pixel size a request is expected to deliver; `.aspectFit` shapes
    /// the target box to the asset's aspect ratio.
    private static func expectedSize(forAsset asset: PHAsset,
                                     targetSize: CGSize,
                                     contentMode: PHImageContentMode) -> CGSize {
        guard contentMode == .aspectFit,
              asset.pixelWidth > 0,
              asset.pixelHeight > 0 else { return targetSize }
        let aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        let boxAspect = targetSize.width / max(targetSize.height, 1)
        if aspect >= boxAspect {
            return CGSize(width: targetSize.width,
                          height: max((targetSize.width / aspect).rounded(.up), 1))
        }
        return CGSize(width: max((targetSize.height * aspect).rounded(.up), 1),
                      height: targetSize.height)
    }

    /// Whether a delivered frame already covers the expected size, so an
    /// exact high-quality follow-up request can be skipped.
    private static func frame(_ image: UIImage, covers expected: CGSize) -> Bool {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        return width >= expected.width * 0.95 && height >= expected.height * 0.95
    }
}
