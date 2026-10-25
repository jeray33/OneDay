import XCTest
@testable import MediaFilter

final class VideoCloudDedupTests: XCTestCase {
    private var directory: URL!
    private var cacheURL: URL { directory.appendingPathComponent("digests.json") }
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyUnrestrictedNonCellularWiFiAllowsDownloads() {
        XCTAssertTrue(VideoDownloadPolicy.allows(satisfied: true, wifi: true, cellular: false,
                                                 expensive: false, constrained: false))
        XCTAssertFalse(VideoDownloadPolicy.allows(satisfied: false, wifi: true, cellular: false,
                                                  expensive: false, constrained: false))
        XCTAssertFalse(VideoDownloadPolicy.allows(satisfied: true, wifi: false, cellular: true,
                                                  expensive: false, constrained: false))
        XCTAssertFalse(VideoDownloadPolicy.allows(satisfied: true, wifi: true, cellular: true,
                                                  expensive: false, constrained: false))
        XCTAssertFalse(VideoDownloadPolicy.allows(satisfied: true, wifi: true, cellular: false,
                                                  expensive: true, constrained: false))
        XCTAssertFalse(VideoDownloadPolicy.allows(satisfied: true, wifi: true, cellular: false,
                                                  expensive: false, constrained: true))
    }

    func testVerifiedDigestsSurviveRelaunchButNotContentVersionChanges() {
        let store = VerifiedVideoDigestStore(url: cacheURL)
        store.record(a, for: "tracks-v1|asset|version1")
        store.flush()
        let reloaded = VerifiedVideoDigestStore(url: cacheURL)
        XCTAssertEqual(reloaded.digest(for: "tracks-v1|asset|version1"), a)
        XCTAssertNil(reloaded.digest(for: "tracks-v1|asset|version2"))
        XCTAssertNil(reloaded.digest(for: "tracks-v2|asset|version1"))
        XCTAssertNil(reloaded.digest(for: "file|asset|version1"))
    }

    func testCacheEvictsOnlyLeastRecentlyUsedEntry() {
        let store = VerifiedVideoDigestStore(url: cacheURL, capacity: 2)
        store.record(a, for: "a")
        store.record(b, for: "b")
        XCTAssertEqual(store.digest(for: "a"), a)
        store.record(a, for: "c")
        store.flush()
        XCTAssertNil(store.digest(for: "b"))
        XCTAssertEqual(store.digest(for: "a"), a)
        XCTAssertEqual(store.digest(for: "c"), a)
        let reloaded = VerifiedVideoDigestStore(url: cacheURL, capacity: 2)
        XCTAssertNil(reloaded.digest(for: "b"))
        XCTAssertEqual(reloaded.digest(for: "a"), a)
    }

    func testInvalidDigestsAndCorruptCachesAreIgnored() throws {
        try Data("not-a-cache".utf8).write(to: cacheURL)
        let store = VerifiedVideoDigestStore(url: cacheURL)
        for digest in ["", "incomplete", String(repeating: "x", count: 64)] {
            store.record(digest, for: "bad")
            XCTAssertNil(store.digest(for: "bad"))
        }
        store.record(a, for: "valid")
        store.flush()
        XCTAssertEqual(VerifiedVideoDigestStore(url: cacheURL).digest(for: "valid"), a)
    }
}
