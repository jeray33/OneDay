import Photos
import UniformTypeIdentifiers

nonisolated enum MediaCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case photo
    case video
    case screenshot
    case panorama
    case otherImage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "照片"
        case .video: return "视频"
        case .screenshot: return "截屏与录屏"
        case .panorama: return "全景与长图"
        case .otherImage: return "其他图片"
        }
    }

    var icon: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .screenshot: return "rectangle.on.rectangle"
        case .panorama: return "panorama"
        case .otherImage: return "photo.on.rectangle"
        }
    }
}

/// Independently persisted media-category selections for the tunnel and day view.
nonisolated struct MediaCategorySelection: RawRepresentable, Equatable, Hashable, Sendable {
    static let rewindStorageKey = "OneDay.rewindMediaCategories"
    static let dayStorageKey = "OneDay.dayMediaCategories"

    var rawValue: String {
        [showsPhotos, showsVideos, showsScreenshots, showsPanoramas, showsOtherImages]
            .map { $0 ? "1" : "0" }
            .joined()
    }

    var showsPhotos: Bool
    var showsVideos: Bool
    var showsScreenshots: Bool
    var showsPanoramas: Bool
    var showsOtherImages: Bool

    init(
        showsPhotos: Bool = true,
        showsVideos: Bool = true,
        showsScreenshots: Bool = true,
        showsPanoramas: Bool = true,
        showsOtherImages: Bool = true
    ) {
        self.showsPhotos = showsPhotos
        self.showsVideos = showsVideos
        self.showsScreenshots = showsScreenshots
        self.showsPanoramas = showsPanoramas
        self.showsOtherImages = showsOtherImages
    }

    init?(rawValue: String) {
        let flags = Array(rawValue)
        guard (flags.count == 4 || flags.count == 5),
              flags.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            return nil
        }
        showsPhotos = flags[0] == "1"
        showsVideos = flags[1] == "1"
        showsScreenshots = flags[2] == "1"
        showsPanoramas = flags[3] == "1"
        // Four-flag preferences predate this category. Preserve every old flag.
        showsOtherImages = flags.count == 4 || flags[4] == "1"
    }

    static let all = MediaCategorySelection()

    static func stored(
        forKey key: String,
        default defaultValue: MediaCategorySelection = .all,
        in defaults: UserDefaults = .standard
    ) -> MediaCategorySelection {
        guard let rawValue = defaults.string(forKey: key),
              let selection = MediaCategorySelection(rawValue: rawValue) else {
            return defaultValue
        }
        return selection
    }

    func save(forKey key: String, in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: key)
    }

    func includes(_ category: MediaCategory) -> Bool {
        switch category {
        case .photo: return showsPhotos
        case .video: return showsVideos
        case .screenshot: return showsScreenshots
        case .panorama: return showsPanoramas
        case .otherImage: return showsOtherImages
        }
    }

    func setting(_ category: MediaCategory, enabled: Bool) -> MediaCategorySelection {
        var result = self
        switch category {
        case .photo: result.showsPhotos = enabled
        case .video: result.showsVideos = enabled
        case .screenshot: result.showsScreenshots = enabled
        case .panorama: result.showsPanoramas = enabled
        case .otherImage: result.showsOtherImages = enabled
        }
        return result
    }

    var includingPhotos: MediaCategorySelection {
        setting(.photo, enabled: true)
    }

    var needsImageClassification: Bool { showsPhotos != showsOtherImages }

    func includes(_ asset: PHAsset) -> Bool {
        guard let category = MediaFilter.category(for: asset) else { return false }
        return includes(category)
    }
}

/// Classifies Photos assets into the categories exposed by the rewind and day menus.
nonisolated enum MediaFilter {
    static func category(for asset: PHAsset) -> MediaCategory? {
        let base = category(
            mediaType: asset.mediaType,
            subtypes: asset.mediaSubtypes,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
        guard base == .photo else { return base }
        return category(
            mediaType: asset.mediaType,
            subtypes: asset.mediaSubtypes,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            imageClassification: ImageClassificationStore.shared.classification(
                for: asset.localIdentifier, modificationDate: asset.modificationDate
            ),
            override: ImageClassificationStore.shared.override(for: asset.localIdentifier),
            isBurst: asset.representsBurst
        )
    }

    static func category(
        mediaType: PHAssetMediaType,
        subtypes: PHAssetMediaSubtype,
        pixelWidth: Int,
        pixelHeight: Int,
        imageClassification: ImageClassification = .unknown,
        override: ImageCategoryOverride = .automatic,
        isBurst: Bool = false
    ) -> MediaCategory? {
        switch mediaType {
        case .image:
            // Screenshot takes precedence over panorama/long-image classification.
            if subtypes.contains(.photoScreenshot) { return .screenshot }
            if subtypes.contains(.photoPanorama) { return .panorama }

            let shortSide = min(pixelWidth, pixelHeight)
            let longSide = max(pixelWidth, pixelHeight)
            if shortSide > 0, Double(longSide) / Double(shortSide) >= 3 {
                return .panorama
            }
            if override == .photo { return .photo }
            if override == .otherImage { return .otherImage }
            if isBurst || hasPhotoSubtype(subtypes) { return .photo }
            return imageClassification == .otherImage ? .otherImage : .photo

        case .video:
            if subtypes.contains(.videoScreenRecording) { return .screenshot }
            return .video

        default:
            return nil
        }
    }

    static func isEligible(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image || asset.mediaType == .video
    }

    static func supportsImageClassification(_ asset: PHAsset) -> Bool {
        // Ignore cached/overridden results when deciding whether the menu applies.
        category(
            mediaType: asset.mediaType,
            subtypes: asset.mediaSubtypes,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        ) == .photo
    }

    static func hasPhotoSubtype(_ subtypes: PHAssetMediaSubtype) -> Bool {
        !subtypes.intersection([.photoLive, .photoDepthEffect, .photoHDR, .spatialMedia]).isEmpty
    }

    static func isPhotoResourceType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage) || type.conforms(to: .gif)
    }
}
