import Photos
import XCTest
@testable import MediaFilter

final class SharedVideoClassificationTests: XCTestCase {
    private func category(shared: Bool, override: ImageCategoryOverride = .automatic,
                          subtypes: PHAssetMediaSubtype = []) -> MediaCategory? {
        MediaFilter.category(
            mediaType: .video, subtypes: subtypes, pixelWidth: 1920, pixelHeight: 1080,
            imageClassification: .otherImage, override: override, isSharedVideo: shared)
    }

    func testSharedVideoIgnoresOldAutomaticOtherClassification() {
        XCTAssertEqual(category(shared: true), .photoVideo)
        XCTAssertEqual(category(shared: false), .otherImage)
    }

    func testManualChoicesAndScreenRecordingsStillWin() {
        XCTAssertEqual(category(shared: true, override: .otherImage), .otherImage)
        XCTAssertEqual(category(shared: true, override: .screenshot), .screenshot)
        XCTAssertEqual(category(shared: true, override: .photo), .photoVideo)
        XCTAssertEqual(category(shared: true, subtypes: .videoScreenRecording), .screenshot)
    }

    func testSharedAndStreamedVideoDetectionDoesNotIncludePhotos() {
        XCTAssertTrue(MediaFilter.isSharedVideo(mediaType: .video, subtypes: [], sourceType: .typeCloudShared))
        XCTAssertTrue(MediaFilter.isSharedVideo(mediaType: .video, subtypes: .videoStreamed, sourceType: .typeUserLibrary))
        XCTAssertFalse(MediaFilter.isSharedVideo(mediaType: .image, subtypes: [], sourceType: .typeCloudShared))
        XCTAssertFalse(MediaFilter.isSharedVideo(mediaType: .video, subtypes: [], sourceType: .typeUserLibrary))
    }

    func testRepairPersistsWithoutClearingOtherResultsOrManualChoices() async {
        let suite = "SharedVideoClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("cache.json")
        let store = ImageClassificationStore(defaults: defaults, cacheURL: url)
        let date = Date(timeIntervalSince1970: 100)
        let generation = store.currentGeneration
        for id in ["shared", "manual", "unrelated-photo"] {
            store.record(.otherImage, for: id, modificationDate: date, generation: generation)
        }
        store.setOverride(.otherImage, for: "manual")
        for id in ["shared", "manual"] {
            XCTAssertTrue(store.repairSharedVideoClassification(
                for: id, modificationDate: date, generation: generation))
        }
        XCTAssertFalse(store.repairSharedVideoClassification(
            for: "shared", modificationDate: date, generation: generation))
        await store.persist()
        let reloaded = ImageClassificationStore(defaults: defaults, cacheURL: url)
        XCTAssertEqual(reloaded.classification(for: "shared", modificationDate: date), .photo)
        XCTAssertEqual(reloaded.classification(for: "manual", modificationDate: date), .photo)
        XCTAssertEqual(reloaded.override(for: "manual"), .otherImage)
        XCTAssertEqual(reloaded.classification(for: "unrelated-photo", modificationDate: date), .otherImage)
        reloaded.setOverride(.automatic, for: "manual")
        XCTAssertEqual(reloaded.classification(for: "manual", modificationDate: date), .photo)
    }

    func testRepairRejectsStaleVersionsAndGenerations() {
        let suite = "SharedVideoClassificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImageClassificationStore(defaults: defaults, cacheURL: nil)
        let date = Date(timeIntervalSince1970: 100)
        let generation = store.currentGeneration
        store.record(.otherImage, for: "shared", modificationDate: date, generation: generation)
        XCTAssertFalse(store.repairSharedVideoClassification(
            for: "shared", modificationDate: date.addingTimeInterval(1), generation: generation))
        store.libraryDidChange()
        XCTAssertFalse(store.repairSharedVideoClassification(
            for: "shared", modificationDate: date, generation: generation))
        XCTAssertEqual(store.classification(for: "shared", modificationDate: date), .otherImage)
    }
}
