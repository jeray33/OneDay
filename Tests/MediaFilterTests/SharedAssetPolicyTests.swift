import XCTest
@testable import MediaFilter

final class SharedAssetPolicyTests: XCTestCase {
    private func resolve(foreign: Bool,
                         systemDelete: Bool,
                         systemEdit: Bool) -> SharedAssetPolicy {
        SharedAssetPolicy.resolve(.init(
            isForeignShared: foreign,
            systemAllowsDelete: systemDelete,
            systemAllowsEditProperties: systemEdit))
    }

    func testForeignSharedIsReadOnlyEvenWhenSystemAllowsEdits() {
        let policy = resolve(foreign: true, systemDelete: true, systemEdit: true)
        XCTAssertFalse(policy.canDelete)
        XCTAssertFalse(policy.canHide)
        XCTAssertFalse(policy.canEditAlbums)
        XCTAssertFalse(policy.canFavorite)
        XCTAssertTrue(policy.canClassify)
    }

    func testOwnItemFollowsSystemPermissions() {
        let policy = resolve(foreign: false, systemDelete: true, systemEdit: true)
        XCTAssertTrue(policy.canDelete)
        XCTAssertTrue(policy.canHide)
        XCTAssertTrue(policy.canEditAlbums)
        XCTAssertTrue(policy.canFavorite)
        XCTAssertTrue(policy.canClassify)
    }

    func testSystemRefusalBlocksOwnItems() {
        let policy = resolve(foreign: false, systemDelete: false, systemEdit: false)
        XCTAssertFalse(policy.canDelete)
        XCTAssertFalse(policy.canHide)
        XCTAssertFalse(policy.canEditAlbums)
        XCTAssertFalse(policy.canFavorite)
        XCTAssertTrue(policy.canClassify)
    }

    func testMixedSystemPermissionsAreHonored() {
        let policy = resolve(foreign: false, systemDelete: false, systemEdit: true)
        XCTAssertFalse(policy.canDelete)
        XCTAssertTrue(policy.canHide)
        XCTAssertTrue(policy.canEditAlbums)
        XCTAssertTrue(policy.canFavorite)
        XCTAssertTrue(policy.canClassify)
    }

    func testClassificationIsAlwaysAvailable() {
        for foreign in [false, true] {
            for systemDelete in [false, true] {
                for systemEdit in [false, true] {
                    let policy = resolve(foreign: foreign,
                                         systemDelete: systemDelete,
                                         systemEdit: systemEdit)
                    XCTAssertTrue(policy.canClassify)
                }
            }
        }
    }
}
