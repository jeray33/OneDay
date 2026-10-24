import Photos
import UniformTypeIdentifiers

nonisolated enum MediaCategory: String, CaseIterable, Hashable, Identifiable, Sendable {
    case photoVideo
    case screenshot
    case otherImage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photoVideo: return "照片和视频（包括全景）"
        case .screenshot: return "截图和录屏"
        case .otherImage: return "其它（包括长图和无拍摄信息的视频）"
        }
    }

    var tabLabel: String {
        switch self {
        case .photoVideo: return "照片和视频"
        case .screenshot: return "截图和录屏"
        case .otherImage: return "其它"
        }
    }

    var icon: String {
        switch self {
        case .photoVideo: return "camera"
        case .screenshot: return "apps.iphone"
        case .otherImage: return "photo"
        }
    }
}

/// Tunnel toggles. The day body uses a single, non-persisted category Tab instead.
nonisolated struct MediaCategorySelection: RawRepresentable, Equatable, Hashable, Sendable {
    static let rewindStorageKey = "OneDay.rewindMediaCategories"

    var rawValue: String {
        [showsPhotosAndVideos, showsScreenshots, showsOtherImages]
            .map { $0 ? "1" : "0" }
            .joined()
    }

    var showsPhotosAndVideos: Bool
    var showsScreenshots: Bool
    var showsOtherImages: Bool

    init(
        showsPhotosAndVideos: Bool = true,
        showsScreenshots: Bool = true,
        showsOtherImages: Bool = true
    ) {
        self.showsPhotosAndVideos = showsPhotosAndVideos
        self.showsScreenshots = showsScreenshots
        self.showsOtherImages = showsOtherImages
    }

    init?(rawValue: String) {
        let flags = Array(rawValue)
        guard (3...5).contains(flags.count),
              flags.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            return nil
        }
        if flags.count == 3 {
            showsPhotosAndVideos = flags[0] == "1"
            showsScreenshots = flags[1] == "1"
            showsOtherImages = flags[2] == "1"
        } else {
            // Legacy tunnel photos were always visible, even if the saved bit was off.
            showsPhotosAndVideos = true
            showsScreenshots = flags[2] == "1"
            // Split the former panorama/long-image group without losing long images.
            showsOtherImages = flags[3] == "1" || flags.count == 4 || flags[4] == "1"
        }
    }

    static let all = MediaCategorySelection()

    static func stored(
        forKey key: String,
        default defaultValue: MediaCategorySelection = .all,
        in defaults: UserDefaults = .standard
    ) -> MediaCategorySelection {
        let selection = defaults.string(forKey: key)
            .flatMap(MediaCategorySelection.init(rawValue:)) ?? defaultValue
        let result = key == rewindStorageKey ? selection.includingPrimary : selection
        if key == rewindStorageKey, defaults.string(forKey: key) != result.rawValue {
            result.save(forKey: key, in: defaults)
        }
        return result
    }

    func save(forKey key: String, in defaults: UserDefaults = .standard) {
        let selection = key == Self.rewindStorageKey ? includingPrimary : self
        defaults.set(selection.rawValue, forKey: key)
    }

    func includes(_ category: MediaCategory) -> Bool {
        switch category {
        case .photoVideo: return showsPhotosAndVideos
        case .screenshot: return showsScreenshots
        case .otherImage: return showsOtherImages
        }
    }

    func setting(_ category: MediaCategory, enabled: Bool) -> MediaCategorySelection {
        var result = self
        switch category {
        case .photoVideo: result.showsPhotosAndVideos = enabled
        case .screenshot: result.showsScreenshots = enabled
        case .otherImage: result.showsOtherImages = enabled
        }
        return result
    }

    var includingPrimary: MediaCategorySelection {
        setting(.photoVideo, enabled: true)
    }

    var needsImageClassification: Bool { showsPhotosAndVideos != showsOtherImages }

    var respondsToClassificationChanges: Bool {
        needsImageClassification || showsPhotosAndVideos != showsScreenshots
    }

    func includes(_ asset: PHAsset) -> Bool {
        guard let category = MediaFilter.category(for: asset) else { return false }
        return includes(category)
    }
}

/// Classifies Photos assets into the categories exposed by the rewind and day menus.
nonisolated enum MediaFilter {
    static func category(for asset: PHAsset) -> MediaCategory? {
        // Do not use the coarse category as a guard: it also contains videos and
        // panoramas, and long images must still respect a manual correction.
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
            if subtypes.contains(.photoPanorama) { return .photoVideo }

            if override == .photo { return .photoVideo }
            if override == .screenshot { return .screenshot }
            if override == .otherImage { return .otherImage }

            let shortSide = min(pixelWidth, pixelHeight)
            let longSide = max(pixelWidth, pixelHeight)
            if shortSide > 0, Double(longSide) / Double(shortSide) >= 3 {
                return .otherImage
            }
            if isBurst || hasPhotoSubtype(subtypes) { return .photoVideo }
            return imageClassification == .otherImage ? .otherImage : .photoVideo

        case .video:
            if subtypes.contains(.videoScreenRecording) { return .screenshot }
            if override == .photo { return .photoVideo }
            if override == .screenshot { return .screenshot }
            if override == .otherImage { return .otherImage }
            // Timelapse and slo-mo only come from the Camera app.
            if hasCameraVideoSubtype(subtypes) { return .photoVideo }
            return imageClassification == .otherImage ? .otherImage : .photoVideo

        default:
            return nil
        }
    }

    static func isEligible(_ asset: PHAsset) -> Bool {
        asset.mediaType == .image || asset.mediaType == .video
    }

    static func supportsImageClassification(_ asset: PHAsset) -> Bool {
        supportsImageClassification(mediaType: asset.mediaType, subtypes: asset.mediaSubtypes)
    }

    static func supportsImageClassification(
        mediaType: PHAssetMediaType, subtypes: PHAssetMediaSubtype
    ) -> Bool {
        switch mediaType {
        case .image:
            return subtypes.intersection([.photoScreenshot, .photoPanorama]).isEmpty
        case .video:
            return !subtypes.contains(.videoScreenRecording)
        default:
            return false
        }
    }

    static func needsAutomaticClassification(_ asset: PHAsset) -> Bool {
        guard supportsImageClassification(asset) else { return false }
        if asset.mediaType == .video { return !hasCameraVideoSubtype(asset.mediaSubtypes) }
        let shortSide = min(asset.pixelWidth, asset.pixelHeight)
        let longSide = max(asset.pixelWidth, asset.pixelHeight)
        return shortSide <= 0 || Double(longSide) / Double(shortSide) < 3
    }

    /// Subtypes only the Camera app produces, so no metadata read is needed.
    static func hasCameraVideoSubtype(_ subtypes: PHAssetMediaSubtype) -> Bool {
        !subtypes.intersection([.videoTimelapse, .videoHighFrameRate]).isEmpty
    }

    static func hasPhotoSubtype(_ subtypes: PHAssetMediaSubtype) -> Bool {
        !subtypes.intersection([.photoLive, .photoDepthEffect, .photoHDR, .spatialMedia]).isEmpty
    }

    static func isPhotoResourceType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage) || type.conforms(to: .gif)
    }
}
