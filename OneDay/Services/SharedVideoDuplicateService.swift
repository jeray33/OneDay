import Photos
import AVFoundation
import UIKit
import Vision

/// Hides shared copies whose capture metadata and pictures match. Pictures come
/// from local thumbnails or cached frame prints, so no download is needed.
/// Compressed-track digests only resolve pairs without local pictures, and
/// cloud originals are fetched only over Wi-Fi.
actor SharedVideoDuplicateService {
    static let shared = SharedVideoDuplicateService()
    private let cache = VerifiedVideoDigestStore.shared
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastProgress = Date.distantPast
    private var posterPrints: [String: VNFeaturePrintObservation] = [:]
    private var posterUnavailable = Set<String>()
    private var posterDeadline = Date.distantPast
    private static let downloadConcurrency = 3

    private enum Verdict { case same, different, unknown }

    func duplicateIDs(
        in items: [PhotoItem],
        onUpdate: (@Sendable (Set<String>) async -> Void)? = nil
    ) async -> Set<String> {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return [] }
        lastProgress = .distantPast
        posterUnavailable.removeAll()
        posterDeadline = Date().addingTimeInterval(20)
        let videos = SharedVideoDuplicatePolicy.unique(items, id: \.id).filter {
            $0.isVideo && ($0.sharedSource == nil || $0.sharedSource == .album)
        }
        let byID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        let candidates = videos.compactMap { item -> SharedVideoDuplicatePolicy.Candidate? in
            guard let time = item.creationDate?.timeIntervalSince1970 else { return nil }
            return .init(id: item.id, time: time, duration: item.duration,
                         width: item.asset.pixelWidth, height: item.asset.pixelHeight,
                         isShared: item.sharedSource == .album)
        }
        var unresolved = Set<String>()
        let local = await SharedVideoDuplicatePolicy.duplicateIDs(candidates, onUpdate: { ids in
            await self.publish(ids, to: onUpdate)
        }) { a, b in
            guard let lhs = byID[a.id], let rhs = byID[b.id] else { return false }
            switch await self.verdict(lhs, rhs) {
            case .same: return true
            case .different: return false
            case .unknown:
                unresolved.formUnion([a.id, b.id])
                return false
            }
        }
        guard !Task.isCancelled else { return local }
        await publish(local, to: onUpdate, force: true)
        let pending = unresolved.compactMap { byID[$0] }
            .filter { cache.digest(for: Self.key($0, "tracks-v1")) == nil }
        guard !unresolved.isEmpty else { return local }
        if !pending.isEmpty {
            guard await VideoWiFiAccess.shared.currentPermission() else { return local }
            let order = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($1.id, $0) })
            await prefetchTrackDigests(pending.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] },
                                       deadline: Date().addingTimeInterval(300))
        }
        guard !Task.isCancelled else { return local }
        let resolved = await SharedVideoDuplicatePolicy.duplicateIDs(candidates) { a, b in
            guard let lhs = byID[a.id], let rhs = byID[b.id] else { return false }
            return await self.verdict(lhs, rhs) == .same
        }
        guard !Task.isCancelled else { return local }
        let result = local.union(resolved)
        if result != local { await publish(result, to: onUpdate, force: true) }
        return result
    }

    /// Cached pairs can finish in milliseconds. Avoid rebuilding the day grid
    /// once per pair while retaining prompt updates during slow reads.
    private func publish(
        _ ids: Set<String>, to callback: (@Sendable (Set<String>) async -> Void)?, force: Bool = false
    ) async {
        guard let callback, !Task.isCancelled,
              force || Date().timeIntervalSince(lastProgress) >= 0.3 else { return }
        lastProgress = Date()
        await callback(ids)
    }

    private func verdict(_ a: PhotoItem, _ b: PhotoItem) async -> Verdict {
        guard !Task.isCancelled else { return .unknown }
        if verifiedBytesMatch(a, b) { return .same }
        if let distances = SimilarityFeatureStore.shared.videoFrameDistances(a, b) {
            return SharedVideoDuplicatePolicy.perceptualMatch(distances) ? .same : .different
        }
        guard let lhs = await posterPrint(a), let rhs = await posterPrint(b) else { return .unknown }
        var distance: Float = 0
        guard (try? lhs.computeDistance(&distance, to: rhs)) != nil else { return .unknown }
        return SharedVideoDuplicatePolicy.perceptualMatch([distance]) ? .same : .different
    }

    private func verifiedBytesMatch(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        ["file", "tracks-v1"].contains { kind in
            SharedVideoDuplicatePolicy.contentMatches(
                digestA: cache.digest(for: Self.key(a, kind)), digestB: cache.digest(for: Self.key(b, kind)))
        }
    }

    private nonisolated static func key(_ item: PhotoItem, _ kind: String) -> String {
        "\(kind)|\(item.contentVersion)|\(item.duration)"
    }

    // MARK: Poster pictures

    private func posterPrint(_ item: PhotoItem) async -> VNFeaturePrintObservation? {
        if let cached = posterPrints[item.contentVersion] { return cached }
        guard !posterUnavailable.contains(item.id), Date() < posterDeadline, !Task.isCancelled else { return nil }
        guard let image = await Self.localThumbnail(item.asset), !Task.isCancelled,
              let cgImage = image.cgImage, let print = Self.featurePrint(cgImage) else {
            posterUnavailable.insert(item.id)
            return nil
        }
        if posterPrints.count >= 2048 { posterPrints.removeAll() }
        posterPrints[item.contentVersion] = print
        return print
    }

    private nonisolated static func localThumbnail(_ asset: PHAsset) async -> UIImage? {
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                await ImageLoader.shared.thumbnail(
                    asset: asset, size: CGSize(width: 360, height: 360),
                    contentMode: .aspectFit, allowsNetworkAccess: false)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    private nonisolated static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return nil }
            return request.results?.first
        }
    }

    // MARK: Track digests

    /// A stalled download only skips its own video; the others keep going.
    private func prefetchTrackDigests(_ items: [PhotoItem], deadline: Date) async {
        await withTaskGroup(of: Void.self) { group in
            var queue = items[...]
            for _ in 0..<Self.downloadConcurrency {
                guard let item = queue.popFirst() else { break }
                group.addTask { _ = await self.trackDigest(item, deadline: deadline) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, Date() < deadline,
                      await VideoWiFiAccess.shared.currentPermission(),
                      let item = queue.popFirst() else { continue }
                group.addTask { _ = await self.trackDigest(item, deadline: deadline) }
            }
        }
    }

    private func trackDigest(_ item: PhotoItem, deadline: Date) async -> String? {
        let key = Self.key(item, "tracks-v1")
        if let cached = cache.digest(for: key) { return cached }
        guard !Task.isCancelled, Date() < deadline else { return nil }
        var read = await Self.videoAsset(item.asset, downloads: false, deadline: deadline)
        if read.asset == nil, VideoWiFiAccess.shared.isAllowed, !Task.isCancelled, Date() < deadline {
            read = await Self.videoAsset(item.asset, downloads: true, deadline: deadline)
        }
        guard let asset = read.asset,
              let digest = await VideoContentFingerprint.digest(asset, deadline: deadline),
              !Task.isCancelled, Date() < deadline else { return nil }
        cache.record(digest, for: key)
        return digest
    }

    private struct VideoRead {
        let asset: AVAsset?
    }

    private final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.withLock { last = Date() } }
        var idle: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    }

    /// Large downloads may take minutes; only a download that stops making
    /// progress is abandoned.
    private nonisolated static func videoAsset(_ asset: PHAsset, downloads: Bool, deadline: Date) async -> VideoRead {
        guard !downloads || VideoWiFiAccess.shared.isAllowed else { return .init(asset: nil) }
        let stream = AsyncStream<VideoRead> { continuation in
            let manager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            let clock = ActivityClock()
            options.isNetworkAccessAllowed = downloads
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.progressHandler = { _, _, stop, _ in
                clock.touch()
                if downloads, !VideoWiFiAccess.shared.isAllowed { stop.pointee = true }
            }
            let request = manager.requestAVAsset(forVideo: asset, options: options) { video, mix, info in
                let failed = info?[PHImageErrorKey] != nil
                    || (info?[PHImageCancelledKey] as? Bool ?? false)
                // An external audio mix can change playback while retaining
                // the same underlying file. Do not equate these edits.
                continuation.yield(.init(asset: failed || mix != nil ? nil : video))
                continuation.finish()
            }
            let wifiToken = downloads ? VideoWiFiAccess.shared.observe { allowed in
                if !allowed {
                    manager.cancelImageRequest(request)
                    continuation.finish()
                }
            } : nil
            let stallLimit: TimeInterval = downloads ? 20 : 1
            let timeout = Task {
                while !Task.isCancelled, clock.idle < stallLimit, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard !Task.isCancelled else { return }
                continuation.yield(.init(asset: nil))
                continuation.finish()
                manager.cancelImageRequest(request)
            }
            continuation.onTermination = { reason in
                timeout.cancel()
                if case .cancelled = reason { manager.cancelImageRequest(request) }
                if let wifiToken { VideoWiFiAccess.shared.removeObserver(wifiToken) }
            }
        }
        for await value in stream { return Task.isCancelled ? .init(asset: nil) : value }
        return .init(asset: nil)
    }
}
