import Photos

/// Decides which assets are eligible for the magazine.
/// Screenshots are filtered via fetch predicate; screen recordings via heuristic here.
enum MediaFilter {
    /// Known iPhone/iPad screen pixel sizes (both orientations).
    /// A no-location video matching one of these is treated as a screen recording.
    private static let screenPixelSizes: Set<[Int]> = {
        let portraits = [
            [750, 1334], [828, 1792], [1080, 1920], [1125, 2436],
            [1170, 2532], [1179, 2556], [1206, 2622], [1242, 2208],
            [1242, 2688], [1284, 2778], [1290, 2796], [1320, 2868],
            [1488, 2266], [1536, 2048], [1620, 2160], [1668, 2388],
            [2048, 2732]
        ]
        var set = Set<[Int]>()
        for size in portraits {
            set.insert(size)
            set.insert([size[1], size[0]])
        }
        return set
    }()

    static func isLikelyScreenRecording(_ asset: PHAsset) -> Bool {
        guard asset.mediaType == .video else { return false }
        guard asset.location == nil else { return false }
        return screenPixelSizes.contains([asset.pixelWidth, asset.pixelHeight])
    }

    /// Catches screenshots that are missing the `.photoScreenshot` subtype
    /// (edited screenshots, re-saved images): no location + exact screen resolution.
    static func isLikelyScreenshotImage(_ asset: PHAsset) -> Bool {
        guard asset.mediaType == .image else { return false }
        guard asset.location == nil else { return false }
        return screenPixelSizes.contains([asset.pixelWidth, asset.pixelHeight])
    }

    static func isEligible(_ asset: PHAsset) -> Bool {
        if asset.mediaSubtypes.contains(.photoScreenshot) { return false }
        if isLikelyScreenshotImage(asset) { return false }
        if isLikelyScreenRecording(asset) { return false }
        return asset.mediaType == .image || asset.mediaType == .video
    }
}
