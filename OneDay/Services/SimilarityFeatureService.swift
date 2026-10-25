import Photos
import UIKit
import Vision
import AVFoundation

/// Stores Vision observations intact, avoiding assumptions about vector layout
/// or the distance metric. Revision and preprocessing are part of the cache.
nonisolated final class SimilarityFeatureStore: @unchecked Sendable {
    static let shared = SimilarityFeatureStore()
    private struct Entry: Codable {
        let version: String
        let printData: Data
        let score: Float?
        var videoPrintData: [Data]? = nil
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var observations: [String: VNFeaturePrintObservation] = [:]
    private var videoObservations: [String: [VNFeaturePrintObservation]] = [:]
    private let queue = DispatchQueue(label: "OneDay.similarity-cache")
    private let url: URL?

    private init() {
        url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OneDay/similarity-v2-revision2.plist")
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    private func observation(_ item: PhotoItem) -> VNFeaturePrintObservation? {
        guard let entry = entries[item.id], entry.version == item.contentVersion else { return nil }
        if let cached = observations[item.id] { return cached }
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: entry.printData) else { return nil }
        observations[item.id] = observation
        return observation
    }

    func contains(_ item: PhotoItem) -> Bool {
        lock.withLock {
            item.isVideo ? videoPrints(item) != nil : observation(item) != nil
        }
    }

    func distance(_ a: PhotoItem, _ b: PhotoItem) -> Float? {
        guard a.isVideo == b.isVideo else { return nil }
        if a.isVideo { return videoFrameDistances(a, b).flatMap(VideoSimilarityPolicy.distance) }
        return lock.withLock {
            guard let lhs = observation(a), let rhs = observation(b) else { return nil }
            var distance: Float = 0
            do { try lhs.computeDistance(&distance, to: rhs); return distance }
            catch { return nil }
        }
    }

    /// Per-frame distances at matching sample positions, or nil when either
    /// video has not been analyzed.
    func videoFrameDistances(_ a: PhotoItem, _ b: PhotoItem) -> [Float]? {
        guard a.isVideo, b.isVideo else { return nil }
        return lock.withLock {
            guard VideoSimilarityPolicy.compatibleDurations(a.duration, b.duration),
                  let lhs = videoPrints(a), let rhs = videoPrints(b),
                  lhs.count == rhs.count else { return nil }
            var distances: [Float] = []
            for (left, right) in zip(lhs, rhs) {
                var distance: Float = 0
                do { try left.computeDistance(&distance, to: right) }
                catch { return nil }
                distances.append(distance)
            }
            return distances
        }
    }

    private func videoPrints(_ item: PhotoItem) -> [VNFeaturePrintObservation]? {
        guard let entry = entries[item.id], entry.version == item.contentVersion,
              let data = entry.videoPrintData,
              data.count == VideoSimilarityPolicy.frameFractions.count else { return nil }
        if let cached = videoObservations[item.id] { return cached }
        let prints = data.compactMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
        guard prints.count == data.count else { return nil }
        videoObservations[item.id] = prints
        return prints
    }

    func score(_ item: PhotoItem) -> Float? {
        lock.withLock {
            guard entries[item.id]?.version == item.contentVersion else { return nil }
            return entries[item.id]?.score
        }
    }

    func record(_ item: PhotoItem, observation: VNFeaturePrintObservation, score: Float?) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: observation, requiringSecureCoding: true) else { return }
        lock.withLock {
            entries[item.id] = Entry(version: item.contentVersion, printData: data, score: score)
            observations[item.id] = observation
        }
    }

    func recordVideo(_ item: PhotoItem, prints: [VNFeaturePrintObservation], score: Float?) {
        guard prints.count == VideoSimilarityPolicy.frameFractions.count else { return }
        let data = prints.compactMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        guard data.count == prints.count else { return }
        lock.withLock {
            entries[item.id] = Entry(version: item.contentVersion, printData: Data(),
                                     score: score, videoPrintData: data)
            videoObservations[item.id] = prints
        }
    }

    func persist() {
        let snapshot = lock.withLock { entries }
        guard let url else { return }
        queue.async {
            guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

actor SimilarityFeatureService {
    static let shared = SimilarityFeatureService()

    /// Sequential inference bounds memory and contention with scrolling/cover work.
    func prepare(_ items: [PhotoItem], onUpdate: (@Sendable () async -> Void)? = nil) async {
        let store = SimilarityFeatureStore.shared
        var lastUpdate = Date.distantPast
        for item in items {
            guard !Task.isCancelled else { break }
            if store.contains(item) { continue }
            if item.isVideo {
                await prepareVideo(item)
            } else if let image = await localThumbnail(item.asset),
                      !Task.isCancelled, let cgImage = image.cgImage,
                      let result = analyze(image, cgImage: cgImage) {
                store.record(item, observation: result.print, score: result.score)
            }
            if store.score(item) != nil, Date().timeIntervalSince(lastUpdate) >= 0.5 {
                lastUpdate = Date()
                await onUpdate?()
            }
        }
        store.persist()
    }

    private func localThumbnail(_ asset: PHAsset) async -> UIImage? {
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

    private func analyze(_ image: UIImage, cgImage: CGImage) -> (print: VNFeaturePrintObservation, score: Float?)? {
        autoreleasepool {
            let feature = VNGenerateImageFeaturePrintRequest()
            feature.revision = VNGenerateImageFeaturePrintRequestRevision2
            feature.imageCropAndScaleOption = .scaleFit
            let orientation: CGImagePropertyOrientation
            switch image.imageOrientation {
            case .up: orientation = .up
            case .down: orientation = .down
            case .left: orientation = .left
            case .right: orientation = .right
            case .upMirrored: orientation = .upMirrored
            case .downMirrored: orientation = .downMirrored
            case .leftMirrored: orientation = .leftMirrored
            case .rightMirrored: orientation = .rightMirrored
            @unknown default: orientation = .up
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            guard (try? handler.perform([feature])) != nil,
                  let observation = feature.results?.first else { return nil }
            let aesthetics = VNCalculateImageAestheticsScoresRequest()
            try? handler.perform([aesthetics])
            let sharpness = PhotoSharpnessRanker.score(image).map { Float(log1p($0) / 12) } ?? 0
            let score = aesthetics.results?.first.map { $0.overallScore + 0.15 * sharpness }
            return (observation, score)
        }
    }

    private func prepareVideo(_ item: PhotoItem) async {
        guard !VideoSimilarityPolicy.sampleTimes(duration: item.duration).isEmpty,
              let asset = await localVideoAsset(item.asset),
              (asset as? AVURLAsset)?.url.isFileURL == true, !Task.isCancelled else { return }
        guard let duration = try? await asset.load(.duration) else { return }
        let times = VideoSimilarityPolicy.sampleTimes(duration: duration.seconds)
        guard times.count == VideoSimilarityPolicy.frameFractions.count else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        // Exact sampling prevents the same distant keyframe being reused for
        // all three positions in a short video.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let deadline = Date().addingTimeInterval(2)
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            generator.cancelAllCGImageGeneration()
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            var prints: [VNFeaturePrintObservation] = []
            var scores: [Float] = []
            var previousTime = -Double.infinity
            for time in times {
                guard !Task.isCancelled, Date() < deadline,
                      let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
                      !Task.isCancelled, Date() < deadline, frame.actualTime.seconds.isFinite,
                      frame.actualTime.seconds > previousTime,
                      let result = analyze(UIImage(cgImage: frame.image), cgImage: frame.image) else { return }
                previousTime = frame.actualTime.seconds
                prints.append(result.print)
                if let score = result.score { scores.append(score) }
            }
            guard !Task.isCancelled else { return }
            SimilarityFeatureStore.shared.recordVideo(
                item, prints: prints,
                score: scores.count == prints.count ? scores.reduce(0, +) / Float(scores.count) : nil)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    /// A cancelled scan terminates the stream and cancels the PhotoKit read.
    /// Cloud-only videos return nil, never a request to download them.
    private func localVideoAsset(_ asset: PHAsset) async -> AVAsset? {
        let stream = AsyncStream<AVAsset?> { continuation in
            let manager = PHImageManager.default()
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.deliveryMode = .highQualityFormat
            let requestID = manager.requestAVAsset(forVideo: asset, options: options) { video, _, info in
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                let failed = info?[PHImageErrorKey] != nil
                continuation.yield(cancelled || failed ? nil : video)
                continuation.finish()
            }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                continuation.finish()
                manager.cancelImageRequest(requestID)
            }
            continuation.onTermination = { reason in
                timeout.cancel()
                if case .cancelled = reason { manager.cancelImageRequest(requestID) }
            }
        }
        for await video in stream { return Task.isCancelled ? nil : video }
        return nil
    }
}
