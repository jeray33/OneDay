import Photos
import UIKit
import ImageIO
import ObjectiveC
import OSLog

private let log = Logger(subsystem: "com.oneday", category: "PhotoCaption")

/// Reads and writes a photo's caption, i.e. the text shown in the Photos app's
/// "Add a Caption" field.
///
/// iOS stores that caption in the Photos database only; it is never written into the
/// file's EXIF/IPTC. There is no public API for it, so the native value is reached through
/// `-[PHAsset descriptionProperties].assetDescription` for reads and
/// `-[PHAssetChangeRequest setAssetDescription:]` for writes. Both are resolved at runtime
/// and silently skipped when unavailable, in which case captions fall back to embedded
/// IPTC/TIFF metadata (which only third-party tools tend to populate).
@MainActor
final class PhotoCaptionManager {
    static let shared = PhotoCaptionManager()

    private init() {
        Self.purgeLegacyEmptyEntries()
    }

    /// Positive-only cache. Absent captions are never cached, so a caption added later in
    /// the Photos app still shows up on the next read.
    private var memoryCache: [String: String] = [:]
    private static let userDefaultsPrefix = "OneDay.caption."

    // MARK: Read

    /// Returns the caption for an asset, or nil if none is set.
    func caption(for asset: PHAsset) async -> String? {
        let id = asset.localIdentifier

        if let native = Self.nativeCaption(for: asset) {
            store(native, for: id)
            return native
        }

        if let cached = memoryCache[id] {
            return cached
        }

        if let saved = UserDefaults.standard.string(forKey: Self.userDefaultsPrefix + id),
           !saved.isEmpty {
            memoryCache[id] = saved
            return saved
        }

        if let embedded = await Self.embeddedCaption(for: asset) {
            store(embedded, for: id)
            return embedded
        }

        return nil
    }

    // MARK: Write

    /// Writes the caption back to the Photos library and updates local caches.
    func setCaption(_ caption: String?, for asset: PHAsset) async throws {
        let text = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try await Self.writeNativeCaption(text, for: asset)
        store(text, for: asset.localIdentifier)
    }

    /// Clears cached captions. Call after photos are edited or replaced.
    func clearCache() {
        memoryCache.removeAll()
    }

    // MARK: - Private: cache

    private func store(_ caption: String, for id: String) {
        let key = Self.userDefaultsPrefix + id
        if caption.isEmpty {
            memoryCache.removeValue(forKey: id)
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            memoryCache[id] = caption
            UserDefaults.standard.set(caption, forKey: key)
        }
    }

    /// Earlier builds persisted an empty string when no caption was found, which permanently
    /// masked captions added later. Remove those poisoned entries once at startup.
    private static func purgeLegacyEmptyEntries() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(userDefaultsPrefix) && (value as? String)?.isEmpty == true {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private: native caption

    private static let descriptionPropertiesSelector = NSSelectorFromString("descriptionProperties")
    private static let assetDescriptionSelector = NSSelectorFromString("assetDescription")
    private static let setAssetDescriptionSelector = NSSelectorFromString("setAssetDescription:")

    /// True when the runtime still exposes the private caption accessors.
    nonisolated static var supportsNativeCaption: Bool {
        PHAsset.instancesRespond(to: descriptionPropertiesSelector)
            && PHAssetChangeRequest.instancesRespond(to: setAssetDescriptionSelector)
    }

    private nonisolated static func nativeCaption(for asset: PHAsset) -> String? {
        guard asset.responds(to: descriptionPropertiesSelector),
              let properties = asset.perform(descriptionPropertiesSelector)?.takeUnretainedValue() as? NSObject,
              properties.responds(to: assetDescriptionSelector),
              let value = properties.perform(assetDescriptionSelector)?.takeUnretainedValue() as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    private nonisolated static func writeNativeCaption(_ caption: String, for asset: PHAsset) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized else {
            log.error("caption write blocked: authorization status \(status.rawValue, privacy: .public)")
            throw CaptionError.notAuthorized
        }
        guard PHAssetChangeRequest.instancesRespond(to: setAssetDescriptionSelector) else {
            log.error("caption write blocked: setAssetDescription: unavailable on this iOS version")
            throw CaptionError.unsupported
        }
        guard asset.canPerform(.properties) else {
            log.error("caption write blocked: asset does not allow property edits")
            throw CaptionError.notEditable
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.perform(setAssetDescriptionSelector, with: caption as NSString)
            }
        } catch {
            let ns = error as NSError
            log.error("caption write failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
            throw CaptionError.writeFailed(ns.localizedDescription)
        }

        // The change request can succeed without the value being persisted (the setter is
        // private and may be dropped server-side), so verify by re-reading the asset.
        let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject ?? asset
        let stored = nativeCaption(for: refreshed)
        guard stored == (caption.isEmpty ? nil : caption) else {
            log.error("caption write not persisted: wrote \"\(caption, privacy: .public)\", read back \"\(stored ?? "<nil>", privacy: .public)\"")
            throw CaptionError.notPersisted
        }
    }

    // MARK: - Private: embedded metadata fallback

    private nonisolated static func embeddedCaption(for asset: PHAsset) async -> String? {
        guard asset.mediaType == .image else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: caption(fromImageData: data))
            }
        }
    }

    private nonisolated static func caption(fromImageData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String, !caption.isEmpty {
                return caption
            }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String,
           !description.isEmpty {
            return description
        }
        return nil
    }

    enum CaptionError: Error, LocalizedError {
        case notAuthorized
        case unsupported
        case notEditable
        case notPersisted
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "需要「所有照片」权限才能修改照片说明"
            case .unsupported:   return "当前系统版本不支持修改照片说明"
            case .notEditable:   return "这张照片不允许修改说明（如 iCloud 共享相簿）"
            case .notPersisted:  return "系统未保存这条说明"
            case .writeFailed(let message): return message
            }
        }
    }
}
