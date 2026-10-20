import Photos
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaFilter

final class MediaFilterTests: XCTestCase {
    func testScreenshotWinsOverLongImageClassification() {
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: [.photoScreenshot, .photoPanorama],
                pixelWidth: 6000,
                pixelHeight: 1000
            ),
            .screenshot
        )
    }

    func testPanoramaSubtypeAndLongImageRatio() {
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: .photoPanorama,
                pixelWidth: 4000,
                pixelHeight: 1500
            ),
            .photoVideo
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: [],
                pixelWidth: 3000,
                pixelHeight: 1000
            ),
            .otherImage
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: [],
                pixelWidth: 2999,
                pixelHeight: 1000
            ),
            .photoVideo
        )
    }

    func testPhotoSubtypesRemainInPhotoCategory() {
        for subtype: PHAssetMediaSubtype in [
            .photoLive,
            .photoDepthEffect,
            .photoHDR,
            .spatialMedia
        ] {
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image,
                    subtypes: subtype,
                    pixelWidth: 1200,
                    pixelHeight: 1600
                ),
                .photoVideo
            )
        }
    }

    func testScreenRecordingsAndVideos() {
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .video,
                subtypes: .videoScreenRecording,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            .screenshot
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .video,
                subtypes: .videoTimelapse,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            .photoVideo
        )
    }

    func testTunnelStorageEnforcesPrimaryAndDoesNotOverwriteOldDayPreferences() {
        let suiteName = "MediaCategorySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("00000", forKey: "OneDay.dayMediaCategories")
        let selection = MediaCategorySelection(
            showsPhotosAndVideos: false, showsScreenshots: true, showsOtherImages: false)
        selection.save(forKey: MediaCategorySelection.rewindStorageKey, in: defaults)
        XCTAssertEqual(defaults.string(forKey: MediaCategorySelection.rewindStorageKey), "110")
        XCTAssertEqual(
            MediaCategorySelection.stored(
                forKey: MediaCategorySelection.rewindStorageKey, in: defaults),
            selection.includingPrimary)
        XCTAssertEqual(defaults.string(forKey: "OneDay.dayMediaCategories"), "00000")
    }

    func testAllCategoriesDefaultOnAndTunnelForcesTheWholePrimaryGroup() {
        XCTAssertEqual(MediaCategory.allCases, [.photoVideo, .screenshot, .otherImage])
        XCTAssertEqual(MediaCategorySelection.all.rawValue, "111")
        let hiddenPrimary = MediaCategorySelection.all.setting(.photoVideo, enabled: false)
        XCTAssertFalse(hiddenPrimary.showsPhotosAndVideos)
        XCTAssertTrue(hiddenPrimary.includingPrimary.showsPhotosAndVideos)
    }

    func testAllLegacyFourAndFiveFlagCombinationsMigrateOnce() {
        let suiteName = "MediaCategoryMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for count in [4, 5] {
            for flags in 0..<(1 << count) {
                let raw = (0..<count).map { flags & (1 << $0) == 0 ? "0" : "1" }.joined()
                defaults.set(raw, forKey: MediaCategorySelection.rewindStorageKey)
                let selection = MediaCategorySelection.stored(
                    forKey: MediaCategorySelection.rewindStorageKey, in: defaults)
                XCTAssertTrue(selection.showsPhotosAndVideos, raw)
                XCTAssertEqual(selection.showsScreenshots, flags & 4 != 0, raw)
                XCTAssertEqual(
                    selection.showsOtherImages, count == 4 || flags & 8 != 0 || flags & 16 != 0, raw)
                XCTAssertEqual(defaults.string(forKey: MediaCategorySelection.rewindStorageKey), selection.rawValue)
                XCTAssertEqual(MediaCategorySelection.stored(
                    forKey: MediaCategorySelection.rewindStorageKey, in: defaults), selection)
            }
        }
        for invalid in ["", "1", "11", "111111", "1111x", "xxxx", "1x1"] {
            XCTAssertNil(MediaCategorySelection(rawValue: invalid))
        }
    }

    func testAllThreeCategoryCombinationsAndFourEffectiveTunnelStates() {
        var tunnelStates = Set<MediaCategorySelection>()
        for flags in 0..<8 {
            let raw = (0..<3).map { flags & (1 << $0) == 0 ? "0" : "1" }.joined()
            let selection = MediaCategorySelection(rawValue: raw)!
            XCTAssertEqual(selection.rawValue, raw)
            XCTAssertEqual(MediaCategorySelection(rawValue: selection.rawValue), selection)
            for (index, category) in MediaCategory.allCases.enumerated() {
                XCTAssertEqual(selection.includes(category), flags & (1 << index) != 0)
                XCTAssertTrue(selection.setting(category, enabled: true).includes(category))
                XCTAssertFalse(selection.setting(category, enabled: false).includes(category))
                XCTAssertEqual(
                    selection.includingPrimary.includes(category),
                    category == .photoVideo || selection.includes(category)
                )
            }
            XCTAssertEqual(selection.needsImageClassification, selection.showsPhotosAndVideos != selection.showsOtherImages)
            XCTAssertEqual(selection.respondsToClassificationChanges, raw != "000" && raw != "111")
            tunnelStates.insert(selection.includingPrimary)
        }
        XCTAssertEqual(tunnelStates.count, 4)
        XCTAssertTrue(tunnelStates.allSatisfy(\.showsPhotosAndVideos))
    }

    func testStoredTunnelNormalizesAllThreeFlagStatesAndDamagedPreferences() {
        let suiteName = "MediaCategoryNormalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for mask in 0..<8 {
            let raw = (0..<3).map { mask & (1 << $0) == 0 ? "0" : "1" }.joined()
            defaults.set(raw, forKey: MediaCategorySelection.rewindStorageKey)
            let selection = MediaCategorySelection.stored(
                forKey: MediaCategorySelection.rewindStorageKey, in: defaults)
            XCTAssertEqual(selection.rawValue, "1" + raw.dropFirst())
            XCTAssertEqual(defaults.string(forKey: MediaCategorySelection.rewindStorageKey), selection.rawValue)
        }
        for raw in ["invalid", ""] {
            defaults.set(raw, forKey: MediaCategorySelection.rewindStorageKey)
            XCTAssertEqual(MediaCategorySelection.stored(
                forKey: MediaCategorySelection.rewindStorageKey, in: defaults), .all)
            XCTAssertEqual(defaults.string(forKey: MediaCategorySelection.rewindStorageKey), "111")
        }
    }

    func testOrdinaryImagesUseEvidenceAndManualChoices() {
        func category(_ result: ImageClassification, _ choice: ImageCategoryOverride = .automatic) -> MediaCategory? {
            MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: 1200, pixelHeight: 1600,
                imageClassification: result, override: choice
            )
        }
        XCTAssertEqual(category(.unknown), .photoVideo)
        XCTAssertEqual(category(.photo), .photoVideo)
        XCTAssertEqual(category(.otherImage), .otherImage)
        XCTAssertEqual(category(.otherImage, .photo), .photoVideo)
        XCTAssertEqual(category(.photo, .otherImage), .otherImage)
        XCTAssertEqual(category(.otherImage, .screenshot), .screenshot)
    }

    func testSystemCategoriesTakePrecedenceOverManualChoices() {
        for subtype: PHAssetMediaSubtype in [.photoScreenshot, .photoPanorama] {
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image, subtypes: subtype, pixelWidth: 1200, pixelHeight: 1600,
                    imageClassification: .otherImage, override: .photo
                ),
                subtype == .photoScreenshot ? .screenshot : .photoVideo
            )
        }
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: 3000, pixelHeight: 1000,
                imageClassification: .otherImage, override: .otherImage
            ), .otherImage
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .video, subtypes: [], pixelWidth: 1920, pixelHeight: 1080,
                imageClassification: .otherImage, override: .otherImage
            ), .photoVideo
        )
    }

    func testProtectedPhotoSubtypesAndBurstStayPhotosUnlessManuallyCorrected() {
        for subtype: PHAssetMediaSubtype in [.photoLive, .photoDepthEffect, .photoHDR, .spatialMedia] {
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image, subtypes: subtype, pixelWidth: 1200, pixelHeight: 1600,
                    imageClassification: .otherImage
                ), .photoVideo
            )
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image, subtypes: subtype, pixelWidth: 1200, pixelHeight: 1600,
                    override: .otherImage
                ), .otherImage
            )
        }
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: 1200, pixelHeight: 1600,
                imageClassification: .otherImage, isBurst: true
            ), .photoVideo
        )
    }

    func testLongImagesCanBeCorrectedWithoutOverridingSystemCategories() {
        for (width, height) in [(3000, 1000), (1000, 3000)] {
            XCTAssertEqual(MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: width, pixelHeight: height,
                override: .photo), .photoVideo)
            XCTAssertEqual(MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: width, pixelHeight: height,
                override: .screenshot), .screenshot)
            for choice in ImageCategoryOverride.allCases {
                XCTAssertEqual(MediaFilter.category(
                    mediaType: .image, subtypes: .photoScreenshot, pixelWidth: width, pixelHeight: height,
                    override: choice), .screenshot)
                XCTAssertEqual(MediaFilter.category(
                    mediaType: .image, subtypes: .photoPanorama, pixelWidth: width, pixelHeight: height,
                    override: choice), .photoVideo)
            }
        }
    }

    func testClassificationMenuDoesNotBecomeAvailableForVideosOrSystemPanoramas() {
        XCTAssertTrue(MediaFilter.supportsImageClassification(mediaType: .image, subtypes: []))
        for subtypes: PHAssetMediaSubtype in [.photoScreenshot, .photoPanorama] {
            XCTAssertFalse(MediaFilter.supportsImageClassification(mediaType: .image, subtypes: subtypes))
        }
        for subtypes: PHAssetMediaSubtype in [[], .videoScreenRecording, .videoTimelapse] {
            XCTAssertFalse(MediaFilter.supportsImageClassification(mediaType: .video, subtypes: subtypes))
        }
        XCTAssertNil(MediaFilter.category(mediaType: .audio, subtypes: [], pixelWidth: 0, pixelHeight: 0))
    }

    func testMetadataUnreadableIsDifferentFromReadableWithoutCameraEvidence() {
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: nil), .unknown)
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: [:]), .unknown)
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: [
            kCGImagePropertyPixelWidth as String: 1200,
            kCGImagePropertyPixelHeight as String: 1600
        ]), .otherImage)
    }

    func testRAWAndGIFAreProtectedButJPEGAndPNGAreNotAssumedToBeCameraPhotos() {
        XCTAssertTrue(MediaFilter.isPhotoResourceType(UTType.rawImage.identifier))
        XCTAssertTrue(MediaFilter.isPhotoResourceType(UTType.gif.identifier))
        XCTAssertFalse(MediaFilter.isPhotoResourceType(UTType.jpeg.identifier))
        XCTAssertFalse(MediaFilter.isPhotoResourceType(UTType.png.identifier))
    }

    func testCameraEvidenceDoesNotRelyOnLocationDatesOrSoftware() {
        let dimensions: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 1200,
            kCGImagePropertyPixelHeight as String: 1600
        ]
        var properties = dimensions
        properties[kCGImagePropertyTIFFDictionary as String] = [
            kCGImagePropertyTIFFMake as String: "Camera manufacturer",
            kCGImagePropertyTIFFModel as String: "Camera model"
        ]
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: properties), .photo)
        properties[kCGImagePropertyTIFFDictionary as String] = [
            kCGImagePropertyTIFFMake as String: " ",
            kCGImagePropertyTIFFModel as String: "Camera model",
            kCGImagePropertyTIFFSoftware as String: "Photo editor"
        ]
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: properties), .otherImage)
        properties[kCGImagePropertyExifDictionary as String] = [
            kCGImagePropertyExifExposureTime as String: 0.01,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifISOSpeedRatings as String: [100]
        ]
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: properties), .photo)
        properties[kCGImagePropertyExifDictionary as String] = [
            kCGImagePropertyExifLensModel as String: "Lens",
            kCGImagePropertyExifExposureTime as String: 0.01,
            kCGImagePropertyExifFNumber as String: 2.8
        ]
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: properties), .photo)
        properties[kCGImagePropertyExifDictionary as String] = [
            kCGImagePropertyExifExposureTime as String: 0.01
        ]
        XCTAssertEqual(CameraMetadataClassifier.classify(properties: properties), .otherImage)
    }

    func testManualChoicesPersistIndependentlyOfAutomaticCacheAndCanBeReset() {
        let suiteName = "ImageClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        store.setOverride(.otherImage, for: "asset-a")
        store.setOverride(.photo, for: "asset-b")
        store.setOverride(.screenshot, for: "asset-c")
        store.libraryDidChange()
        let reloaded = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        XCTAssertEqual(reloaded.override(for: "asset-a"), .otherImage)
        XCTAssertEqual(reloaded.override(for: "asset-b"), .photo)
        XCTAssertEqual(reloaded.override(for: "asset-c"), .screenshot)
        reloaded.setOverride(.automatic, for: "asset-a")
        let restored = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        XCTAssertEqual(restored.override(for: "asset-a"), .automatic)
        XCTAssertEqual(restored.override(for: "asset-b"), .photo)
    }

    func testAutomaticCachePersistsAndRejectsStaleOrUnknownResults() async throws {
        let suiteName = "ImageClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("classifications.json")
        let store = ImageClassificationStore(defaults: defaults, cacheURL: url)
        let date = Date(timeIntervalSince1970: 100)
        let generation = store.currentGeneration
        XCTAssertTrue(store.record(.otherImage, for: "a", modificationDate: date, generation: generation))
        store.record(.unknown, for: "b", modificationDate: date, generation: generation)
        XCTAssertEqual(store.classification(for: "a", modificationDate: date), .otherImage)
        XCTAssertEqual(store.classification(for: "a", modificationDate: date.addingTimeInterval(1)), .unknown)
        await store.persist()
        let reloaded = ImageClassificationStore(defaults: defaults, cacheURL: url)
        XCTAssertEqual(reloaded.classification(for: "a", modificationDate: date), .otherImage)
        XCTAssertEqual(reloaded.classification(for: "b", modificationDate: date), .unknown)
        reloaded.libraryDidChange()
        XCTAssertFalse(reloaded.record(.photo, for: "a", modificationDate: date, generation: generation))
        XCTAssertEqual(reloaded.classification(for: "a", modificationDate: date), .otherImage)
        XCTAssertTrue(reloaded.record(
            .unknown, for: "a", modificationDate: date, generation: reloaded.currentGeneration
        ))
        XCTAssertEqual(reloaded.classification(for: "a", modificationDate: date), .unknown)
        await reloaded.persist()
        let final = ImageClassificationStore(defaults: defaults, cacheURL: url)
        XCTAssertEqual(final.classification(for: "a", modificationDate: date), .unknown)
    }

    func testDamagedOrOutdatedAutomaticCacheDoesNotLoseManualChoices() throws {
        let suiteName = "ImageClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("classifications.json")
        let store = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        store.setOverride(.otherImage, for: "a")
        for content in [
            "invalid json",
            #"{"version":-1,"entries":{"a":{"classification":"otherImage"}}}"#
        ] {
            try Data(content.utf8).write(to: url)
            let loaded = ImageClassificationStore(defaults: defaults, cacheURL: url)
            XCTAssertEqual(loaded.override(for: "a"), .otherImage)
            XCTAssertEqual(loaded.classification(for: "a", modificationDate: nil), .unknown)
        }
    }

    func testConcurrentCacheUpdatesKeepManualAndAutomaticResultsSeparate() {
        let suiteName = "ImageClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        let generation = store.currentGeneration
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let id = "asset-\(index)"
            store.setOverride(.photo, for: id)
            store.record(.otherImage, for: id, modificationDate: nil, generation: generation)
        }
        for index in 0..<100 {
            let id = "asset-\(index)"
            XCTAssertEqual(store.override(for: id), .photo)
            XCTAssertEqual(store.classification(for: id, modificationDate: nil), .otherImage)
        }
    }
}
