import XCTest
@testable import MediaFilter

final class PreviewInteractionPolicyTests: XCTestCase {
    func testSystemEdgeStartsAreExcludedEvenWithHiddenStatusBar() {
        XCTAssertFalse(PreviewInteractionPolicy.allowsStart(y: 12, height: 844, topInset: 0, bottomInset: 0))
        XCTAssertFalse(PreviewInteractionPolicy.allowsStart(y: 830, height: 844, topInset: 0, bottomInset: 0))
        XCTAssertTrue(PreviewInteractionPolicy.allowsStart(y: 400, height: 844, topInset: 0, bottomInset: 0))
    }

    func testSafeAreasAndClearanceAreExcluded() {
        for y in [CGFloat(0), 59, 67, 802, 810, 844] {
            XCTAssertFalse(PreviewInteractionPolicy.allowsStart(y: y, height: 844, topInset: 59, bottomInset: 34))
        }
        for y in [CGFloat(68), 400, 801] {
            XCTAssertTrue(PreviewInteractionPolicy.allowsStart(y: y, height: 844, topInset: 59, bottomInset: 34))
        }
    }

    func testInterruptedCompletionsStayInvalidAfterReturningToActive() {
        var policy = PreviewInteractionPolicy()
        let old = policy.generation
        XCTAssertTrue(policy.canComplete(old, isActive: true))
        policy.invalidate()
        XCTAssertFalse(policy.canComplete(old, isActive: false))
        XCTAssertFalse(policy.canComplete(old, isActive: true))
        XCTAssertFalse(policy.canComplete(policy.generation, isActive: false))
        XCTAssertTrue(policy.canComplete(policy.generation, isActive: true))
        policy.invalidate()
        XCTAssertFalse(policy.canComplete(old, isActive: true))
    }

    func testCancellationNeverClosesOrStagesEvenPastThreshold() {
        for height in [CGFloat(-600), 600] {
            XCTAssertEqual(PreviewInteractionPolicy.endAction(
                translation: CGSize(width: 0, height: height),
                predicted: CGSize(width: 0, height: height),
                verticalLocked: true, canDelete: true, cancelled: true
            ), .restore)
        }
    }

    func testHorizontalBrowseCannotTurnIntoDeletionAtRelease() {
        XCTAssertEqual(PreviewInteractionPolicy.endAction(
            translation: CGSize(width: 50, height: -300),
            predicted: CGSize(width: 60, height: -600),
            verticalLocked: false, canDelete: true
        ), .browse)
    }

    func testNormalEndThresholdsAndReadOnlyProtection() {
        func action(_ height: CGFloat, predicted: CGFloat = 0, canDelete: Bool = true) -> PreviewInteractionPolicy.EndAction {
            PreviewInteractionPolicy.endAction(
                translation: CGSize(width: 0, height: height),
                predicted: CGSize(width: 0, height: predicted),
                verticalLocked: true, canDelete: canDelete
            )
        }
        XCTAssertEqual(action(-181), .stage)
        XCTAssertEqual(action(-20, predicted: -461), .stage)
        XCTAssertEqual(action(-300, canDelete: false), .restore)
        XCTAssertEqual(action(-20, predicted: -600, canDelete: false), .restore)
        XCTAssertEqual(action(81), .close)
        XCTAssertEqual(action(20, predicted: 241), .close)
        XCTAssertEqual(action(20), .restore)
        XCTAssertEqual(action(-180), .restore)
        XCTAssertEqual(action(80), .restore)
    }

    func testVerticalDragReleasedSidewaysRestores() {
        XCTAssertEqual(PreviewInteractionPolicy.endAction(
            translation: CGSize(width: 400, height: -300),
            predicted: CGSize(width: 500, height: -600),
            verticalLocked: true, canDelete: true
        ), .restore)
    }
}
