import Photos
import ImageIO
import ObjectiveC

/// Reads a photo's caption, i.e. the text shown in the Photos app's
/// "Add a Caption" field.
///
/// iOS stores that caption in the Photos database only; it is never written into the
/// file's EXIF/IPTC. There is no public API for it, so the native value is reached through
/// `-[PHAsset descriptionProperties].assetDescription`, resolved at runtime. When it is
/// unavailable, captions fall back to cached values or embedded IPTC/TIFF metadata
/// (which only third-party tools tend to populate). This service never edits the asset.
@MainActor
final class PhotoCaptionManager {
    static let shared = PhotoCaptionManager()

    private init() {
        Self.purgeLegacyEntries()
    }

    /// Positive-only cache. Absent captions are never cached, so a caption added later in
    /// the Photos app still shows up on the next read.
    private var memoryCache: [String: String] = [:]
    /// Session-only memo of assets whose embedded metadata was already
    /// checked and held nothing (asset id → content version), so bulk caption
    /// loads never re-read whole image files for the same content twice.
    private var embeddedChecked: [String: String] = [:]
    private static let userDefaultsPrefix = "OneDay.caption."

    // MARK: Read

    /// Returns the caption for an asset, or nil if none is set.
    ///
    /// - `embeddedFallback`: also read embedded IPTC/TIFF metadata, which
    ///   requires the asset's image data. Bulk loads pass `false` for a
    ///   cheap first pass and run the bounded fallback separately.
    /// - `allowsNetworkAccess`: the embedded fallback may download the
    ///   original when it only exists in iCloud; bulk loads skip that.
    func caption(for asset: PHAsset,
                 embeddedFallback: Bool = true,
                 allowsNetworkAccess: Bool = true) async -> String? {
        let id = asset.localIdentifier

        let native = await Task.detached(priority: .utility) {
            Self.nativeCaption(for: asset)
        }.value
        guard !Task.isCancelled else { return nil }
        if let native {
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

        guard embeddedFallback else { return nil }
        // A miss is never persisted, so a caption added in Photos shows up on
        // the next read. A local-only miss must not suppress a later explicit
        // request that allows downloading the embedded metadata.
        if !allowsNetworkAccess, embeddedChecked[id] == asset.contentVersion { return nil }

        if let embedded = await Self.embeddedCaption(
            for: asset, allowsNetworkAccess: allowsNetworkAccess) {
            embeddedChecked[id] = nil
            store(embedded, for: id)
            return embedded
        }
        if !allowsNetworkAccess { embeddedChecked[id] = asset.contentVersion }
        return nil
    }

    /// Clears cached captions. Call after photos are edited or replaced.
    func clearCache() {
        memoryCache.removeAll()
        embeddedChecked.removeAll()
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
    /// masked captions added later; they also cached the system placeholders ("Screenshot",
    /// "Screen Recording") iOS generates for captures without a user caption. Remove those
    /// poisoned entries once at startup.
    private static func purgeLegacyEntries() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(userDefaultsPrefix) {
            guard let caption = value as? String,
                  GenericCaptionFilter.userCaption(caption) == nil else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private: native caption

    private nonisolated static let descriptionPropertiesSelector = NSSelectorFromString("descriptionProperties")
    private nonisolated static let assetDescriptionSelector = NSSelectorFromString("assetDescription")

    private nonisolated static func nativeCaption(for asset: PHAsset) -> String? {
        guard asset.responds(to: descriptionPropertiesSelector),
              let properties = asset.perform(descriptionPropertiesSelector)?.takeUnretainedValue() as? NSObject,
              properties.responds(to: assetDescriptionSelector),
              let value = properties.perform(assetDescriptionSelector)?.takeUnretainedValue() as? String
        else { return nil }
        // iOS labels captures that have no user caption ("Screenshot",
        // "Screen Recording"); those placeholders are not 说明文字.
        return GenericCaptionFilter.userCaption(value)
    }

    // MARK: - Private: embedded metadata fallback

    private nonisolated static func embeddedCaption(
        for asset: PHAsset, allowsNetworkAccess: Bool
    ) async -> String? {
        guard asset.mediaType == .image else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = allowsNetworkAccess
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

        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any],
           let caption = GenericCaptionFilter.userCaption(
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String) {
            return caption
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let description = GenericCaptionFilter.userCaption(
            tiff[kCGImagePropertyTIFFImageDescription as String] as? String) {
            return description
        }
        return nil
    }
}
