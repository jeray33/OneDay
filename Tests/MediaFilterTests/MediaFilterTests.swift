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
            .panorama
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: [],
                pixelWidth: 3000,
                pixelHeight: 1000
            ),
            .panorama
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image,
                subtypes: [],
                pixelWidth: 2999,
                pixelHeight: 1000
            ),
            .photo
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
                .photo
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
            .video
        )
    }

    func testSelectionsPersistAndCanBeIndependent() {
        let rewind = MediaCategorySelection.all.setting(.video, enabled: false).setting(.otherImage, enabled: false)
        let day = MediaCategorySelection.all.setting(.photo, enabled: false)

        XCTAssertEqual(MediaCategorySelection(rawValue: rewind.rawValue), rewind)
        XCTAssertEqual(MediaCategorySelection(rawValue: day.rawValue), day)
        let suiteName = "MediaCategorySelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        rewind.save(forKey: MediaCategorySelection.rewindStorageKey, in: defaults)
        day.save(forKey: MediaCategorySelection.dayStorageKey, in: defaults)
        XCTAssertEqual(
            MediaCategorySelection.stored(
                forKey: MediaCategorySelection.rewindStorageKey,
                in: defaults
            ),
            rewind
        )
        XCTAssertEqual(
            MediaCategorySelection.stored(
                forKey: MediaCategorySelection.dayStorageKey,
                in: defaults
            ),
            day
        )
        XCTAssertTrue(rewind.showsPhotos)
        XCTAssertFalse(rewind.showsVideos)
        XCTAssertFalse(rewind.showsOtherImages)
        XCTAssertTrue(day.showsOtherImages)
        XCTAssertFalse(day.showsPhotos)
        XCTAssertTrue(day.showsVideos)
        XCTAssertNotEqual(rewind, day)
    }

    func testAllCategoriesAreEnabledByDefaultAndTunnelCanForcePhotosOn() {
        XCTAssertEqual(MediaCategorySelection.all, MediaCategorySelection(
            showsPhotos: true,
            showsVideos: true,
            showsScreenshots: true,
            showsPanoramas: true
        ))

        let hiddenPhotoSelection = MediaCategorySelection.all.setting(.photo, enabled: false)
        XCTAssertFalse(hiddenPhotoSelection.showsPhotos)
        XCTAssertTrue(hiddenPhotoSelection.includingPhotos.showsPhotos)
    }

    func testOldFourFlagSettingsPreserveEveryExistingChoice() {
        for flags in 0..<16 {
            let raw = (0..<4).map { flags & (1 << $0) == 0 ? "0" : "1" }.joined()
            let selection = MediaCategorySelection(rawValue: raw)
            XCTAssertEqual(selection?.rawValue, raw + "1")
            XCTAssertEqual(selection?.showsOtherImages, true)
        }
        for invalid in ["", "1", "111", "111111", "1111x", "xxxx"] {
            XCTAssertNil(MediaCategorySelection(rawValue: invalid))
        }
    }

    func testAllFiveCategoryCombinationsAndTunnelPhotoEnforcement() {
        for flags in 0..<32 {
            let raw = (0..<5).map { flags & (1 << $0) == 0 ? "0" : "1" }.joined()
            let selection = MediaCategorySelection(rawValue: raw)!
            XCTAssertEqual(selection.rawValue, raw)
            XCTAssertEqual(MediaCategorySelection(rawValue: selection.rawValue), selection)
            for (index, category) in MediaCategory.allCases.enumerated() {
                XCTAssertEqual(selection.includes(category), flags & (1 << index) != 0)
                XCTAssertTrue(selection.setting(category, enabled: true).includes(category))
                XCTAssertFalse(selection.setting(category, enabled: false).includes(category))
                XCTAssertEqual(
                    selection.includingPhotos.includes(category),
                    category == .photo || selection.includes(category)
                )
            }
            XCTAssertEqual(selection.needsImageClassification, selection.showsPhotos != selection.showsOtherImages)
        }
        XCTAssertTrue(MediaCategorySelection.all.showsOtherImages)
    }

    func testOrdinaryImagesUseEvidenceAndManualChoices() {
        func category(_ result: ImageClassification, _ choice: ImageCategoryOverride = .automatic) -> MediaCategory? {
            MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: 1200, pixelHeight: 1600,
                imageClassification: result, override: choice
            )
        }
        XCTAssertEqual(category(.unknown), .photo)
        XCTAssertEqual(category(.photo), .photo)
        XCTAssertEqual(category(.otherImage), .otherImage)
        XCTAssertEqual(category(.otherImage, .photo), .photo)
        XCTAssertEqual(category(.photo, .otherImage), .otherImage)
    }

    func testSystemCategoriesTakePrecedenceOverManualChoices() {
        for subtype: PHAssetMediaSubtype in [.photoScreenshot, .photoPanorama] {
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image, subtypes: subtype, pixelWidth: 1200, pixelHeight: 1600,
                    imageClassification: .otherImage, override: .photo
                ),
                subtype == .photoScreenshot ? .screenshot : .panorama
            )
        }
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .image, subtypes: [], pixelWidth: 3000, pixelHeight: 1000,
                imageClassification: .otherImage, override: .otherImage
            ), .panorama
        )
        XCTAssertEqual(
            MediaFilter.category(
                mediaType: .video, subtypes: [], pixelWidth: 1920, pixelHeight: 1080,
                imageClassification: .otherImage, override: .otherImage
            ), .video
        )
    }

    func testProtectedPhotoSubtypesAndBurstStayPhotosUnlessManuallyCorrected() {
        for subtype: PHAssetMediaSubtype in [.photoLive, .photoDepthEffect, .photoHDR, .spatialMedia] {
            XCTAssertEqual(
                MediaFilter.category(
                    mediaType: .image, subtypes: subtype, pixelWidth: 1200, pixelHeight: 1600,
                    imageClassification: .otherImage
                ), .photo
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
            ), .photo
        )
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
        store.libraryDidChange()
        let reloaded = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        XCTAssertEqual(reloaded.override(for: "asset-a"), .otherImage)
        XCTAssertEqual(reloaded.override(for: "asset-b"), .photo)
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
