import Photos
import AVFoundation
import CryptoKit

/// Suppress only identical files or complete compressed tracks with identical
/// playback information. Cloud candidates may be fetched only over Wi-Fi.
actor SharedVideoDuplicateService {
    static let shared = SharedVideoDuplicateService()
    private let cache = VerifiedVideoDigestStore.shared
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastProgress = Date.distantPast
    private var cloudReadTimedOut = false

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
        cloudReadTimedOut = false
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
        // Publish the fast local result before any cloud work. Each pass has a
        // separate unavailable set so local-only failures can be retried on Wi-Fi.
        let local = await scan(candidates, byID: byID, downloads: false,
                               deadline: Date().addingTimeInterval(10)) { ids in
            await self.publish(ids, to: onUpdate)
        }
        if !local.isEmpty { await publish(local, to: onUpdate, force: true) }
        guard !Task.isCancelled, await VideoWiFiAccess.shared.currentPermission() else { return local }
        let cloud = await scan(candidates, byID: byID, downloads: true,
                               deadline: Date().addingTimeInterval(300)) { ids in
            await self.publish(local.union(ids), to: onUpdate)
        }
        return local.union(cloud)
    }

    /// Cached pairs can finish in milliseconds. Avoid rebuilding the day grid
    /// once per pair while retaining prompt updates during slow cloud reads.
    private func publish(
        _ ids: Set<String>, to callback: (@Sendable (Set<String>) async -> Void)?, force: Bool = false
    ) async {
        guard let callback, !Task.isCancelled,
              force || Date().timeIntervalSince(lastProgress) >= 0.3 else { return }
        lastProgress = Date()
        await callback(ids)
    }

    private func scan(
        _ candidates: [SharedVideoDuplicatePolicy.Candidate], byID: [String: PhotoItem],
        downloads: Bool, deadline: Date,
        onUpdate: (@Sendable (Set<String>) async -> Void)?
    ) async -> Set<String> {
        var unavailable = Set<String>()
        var unavailableTracks = Set<String>()
        return await SharedVideoDuplicatePolicy.duplicateIDs(candidates, onUpdate: onUpdate) { a, b in
            if downloads, await self.cloudReadTimedOut { return false }
            guard Date() < deadline, !Task.isCancelled,
                  !unavailable.contains(a.id), !unavailable.contains(b.id),
                  let lhs = byID[a.id], let rhs = byID[b.id] else { return false }
            guard let left = await self.digest(lhs, deadline: deadline, downloads: downloads) else {
                unavailable.insert(a.id)
                return false
            }
            guard let right = await self.digest(rhs, deadline: deadline, downloads: downloads) else {
                unavailable.insert(b.id)
                return false
            }
            if SharedVideoDuplicatePolicy.contentMatches(digestA: left, digestB: right) { return true }
            guard !unavailableTracks.contains(a.id), !unavailableTracks.contains(b.id) else { return false }
            guard let leftTracks = await self.digest(lhs, deadline: deadline, tracks: true, downloads: downloads) else {
                unavailableTracks.insert(a.id)
                return false
            }
            guard let rightTracks = await self.digest(rhs, deadline: deadline, tracks: true, downloads: downloads) else {
                unavailableTracks.insert(b.id)
                return false
            }
            return SharedVideoDuplicatePolicy.contentMatches(digestA: leftTracks, digestB: rightTracks)
        }
    }

    private func digest(_ item: PhotoItem, deadline: Date, tracks: Bool = false, downloads: Bool) async -> String? {
        let key = "\(tracks ? "tracks-v1" : "file")|\(item.contentVersion)|\(item.duration)"
        if let cached = cache.digest(for: key) { return cached }
        guard !Task.isCancelled, Date() < deadline else { return nil }
        var read = await Self.videoAsset(item.asset, downloads: false, deadline: deadline)
        if read.asset == nil, downloads, VideoWiFiAccess.shared.isAllowed, !Task.isCancelled, Date() < deadline {
            read = await Self.videoAsset(item.asset, downloads: true, deadline: deadline)
            // A stalled Photos download is not a reason to queue minutes of
            // identical waits for every other candidate. Keep verified results.
            if read.timedOut { cloudReadTimedOut = true }
        }
        guard let asset = read.asset else { return nil }
        let result = tracks
            ? await VideoContentFingerprint.digest(asset, deadline: deadline)
            : Self.fileDigest(asset, deadline: deadline)
        guard let digest = result, !Task.isCancelled, Date() < deadline else { return nil }
        cache.record(digest, for: key)
        return digest
    }

    private struct VideoRead {
        let asset: AVAsset?
        var timedOut = false
    }

    private nonisolated static func videoAsset(_ asset: PHAsset, downloads: Bool, deadline: Date) async -> VideoRead {
        guard !downloads || VideoWiFiAccess.shared.isAllowed else { return .init(asset: nil) }
        let stream = AsyncStream<VideoRead> { continuation in
            let manager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = downloads
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.progressHandler = { progress, error, stop, _ in
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
            let seconds = min(downloads ? 15.0 : 1.0, max(0, deadline.timeIntervalSinceNow))
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                continuation.yield(.init(asset: nil, timedOut: true))
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

    private nonisolated static func fileDigest(_ asset: AVAsset, deadline: Date) -> String? {
        guard let url = (asset as? AVURLAsset)?.url, url.isFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var hash = SHA256()
        var count = 0
        do {
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                guard !Task.isCancelled, Date() < deadline else { return nil }
                hash.update(data: data)
                count += data.count
            }
            // Empty or partially read files must never confirm a duplicate.
            guard count == size,
                  let finalSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  finalSize == size else { return nil }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
}
