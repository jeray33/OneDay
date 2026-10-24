import Foundation
import ImageIO

nonisolated enum ImageClassification: String, Codable, Sendable {
    case unknown
    case photo
    case otherImage
}

nonisolated enum ImageCategoryOverride: String, CaseIterable, Sendable {
    case automatic
    case photo
    case screenshot
    case otherImage

    var label: String {
        switch self {
        case .automatic: return "自动判断"
        case .photo: return "归为照片"
        case .screenshot: return "归为截图"
        case .otherImage: return "归为其它"
        }
    }
}

nonisolated enum CameraMetadataClassifier {
    static func classify(properties: [String: Any]?) -> ImageClassification {
        guard let properties,
              (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0 > 0,
              (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0 > 0
        else { return .unknown }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let hasCamera = hasText(tiff[kCGImagePropertyTIFFMake as String])
            && hasText(tiff[kCGImagePropertyTIFFModel as String])
        let hasLens = hasText(exif[kCGImagePropertyExifLensModel as String])
        let exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?
            .contains { $0.doubleValue > 0 } ?? false
        let exposureCount = [exposure > 0, aperture > 0, iso].filter { $0 }.count
        return hasCamera || exposureCount == 3 || (hasLens && exposureCount >= 2) ? .photo : .otherImage
    }

    /// Camera footage carries the recording device in its container metadata
    /// (QuickTime make/model); downloads and re-exports do not.
    static func classifyVideo(make: String?, model: String?) -> ImageClassification {
        hasText(make) && hasText(model) ? .photo : .otherImage
    }

    private static func hasText(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension Notification.Name {
    nonisolated static let imageClassificationChanged = Notification.Name("OneDay.imageClassificationChanged")
}

/// Synchronous snapshots for the existing, thread-safe PhotoKit filtering loops.
/// Only the background classifier writes automatic results; manual choices are separate.
nonisolated final class ImageClassificationStore: @unchecked Sendable {
    static let shared = ImageClassificationStore()
    private static let overrideKey = "OneDay.imageCategoryOverrides"
    private static let rulesVersion = 1

    private struct Entry: Codable {
        let modificationTime: TimeInterval?
        let classification: ImageClassification

        func matches(_ date: Date?) -> Bool {
            if modificationTime == date?.timeIntervalSince1970 { return true }
            // A live preview can still hold the older immutable PHAsset snapshot.
            guard let modificationTime, let date else { return false }
            return modificationTime > date.timeIntervalSince1970
        }
    }

    private struct Cache: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let cacheURL: URL?
    private let persistenceQueue = DispatchQueue(label: "OneDay.image-classification-cache", qos: .utility)
    private var entries: [String: Entry] = [:]
    private var overrides: [String: ImageCategoryOverride] = [:]
    private var generation = 0
    private var activeWork = 0

    init(defaults: UserDefaults = .standard, cacheURL: URL? = ImageClassificationStore.defaultCacheURL()) {
        self.defaults = defaults
        self.cacheURL = cacheURL
        overrides = (defaults.dictionary(forKey: Self.overrideKey) as? [String: String] ?? [:])
            .compactMapValues { value in
                guard let choice = ImageCategoryOverride(rawValue: value), choice != .automatic else { return nil }
                return choice
            }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == Self.rulesVersion {
            entries = cache.entries.filter { $0.value.classification != .unknown }
        }
    }

    private static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OneDay", isDirectory: true)
            .appendingPathComponent("image-classification.json")
    }

    var currentGeneration: Int { lock.withLock { generation } }
    var isIndexing: Bool { lock.withLock { activeWork > 0 } }

    func classification(for id: String, modificationDate: Date?) -> ImageClassification {
        lock.withLock {
            guard let entry = entries[id], entry.matches(modificationDate) else { return .unknown }
            return entry.classification
        }
    }

    func override(for id: String) -> ImageCategoryOverride {
        lock.withLock { overrides[id] ?? .automatic }
    }

    func setOverride(_ choice: ImageCategoryOverride, for id: String) {
        let changed = lock.withLock {
            guard (overrides[id] ?? .automatic) != choice else { return false }
            overrides[id] = choice == .automatic ? nil : choice
            defaults.set(overrides.mapValues(\.rawValue), forKey: Self.overrideKey)
            return true
        }
        if changed { Self.notify(changed: true, finished: true) }
    }

    /// Reject results from a scan that predates a library change.
    @discardableResult
    func record(
        _ result: ImageClassification, for id: String, modificationDate: Date?, generation: Int
    ) -> Bool {
        lock.withLock {
            guard self.generation == generation else { return false }
            let old = entries[id]?.classification ?? .unknown
            if result == .unknown {
                entries[id] = nil
            } else {
                entries[id] = Entry(modificationTime: modificationDate?.timeIntervalSince1970, classification: result)
            }
            return (old == .otherImage) != (result == .otherImage)
        }
    }

    func libraryDidChange() {
        lock.withLock { generation += 1 }
        // Retain known results: modification fingerprints invalidate edited assets.
        // Never delete manual choices merely because limited access hides an asset.
    }

    func beginWork() { lock.withLock { activeWork += 1 } }
    func endWork() { lock.withLock { activeWork = max(0, activeWork - 1) } }

    func persist() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistenceQueue.async { [self] in
                defer { continuation.resume() }
                guard let cacheURL else { return }
                let snapshot = lock.withLock { Cache(version: Self.rulesVersion, entries: entries) }
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                do {
                    try FileManager.default.createDirectory(
                        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try data.write(to: cacheURL, options: .atomic)
                } catch {
                    // The cache is disposable. Manual choices live in UserDefaults.
                }
            }
        }
    }

    static func notify(changed: Bool, finished: Bool) {
        NotificationCenter.default.post(
            name: .imageClassificationChanged, object: nil,
            userInfo: ["changed": changed, "finished": finished]
        )
    }
}
