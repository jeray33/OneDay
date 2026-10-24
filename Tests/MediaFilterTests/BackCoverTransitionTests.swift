import XCTest
import CoreGraphics
@testable import MediaFilter

final class BackCoverTransitionTests: XCTestCase {
    private let h: CGFloat = 800

    private func place(_ t: BackCoverTransition, fromBack: Bool,
                       _ offset: CGFloat) -> BackCoverFlipPlacement {
        .make(transition: t, fromBack: fromBack, offset: offset, height: h)
    }

    func testSavedValueDefaultsToReveal() {
        XCTAssertEqual(BackCoverTransition(savedValue: nil), .reveal)
        XCTAssertEqual(BackCoverTransition(savedValue: "bogus"), .reveal)
        for t in BackCoverTransition.allCases {
            XCTAssertEqual(BackCoverTransition(savedValue: t.rawValue), t)
        }
        XCTAssertEqual(BackCoverTransition.reveal.label, "揭开")
        XCTAssertEqual(BackCoverTransition.sync.label, "同步")
    }

    func testRevealKeepsBackCoverParkedBeneath() {
        let p = place(.reveal, fromBack: false, -300)
        XCTAssertEqual(p.contentOffset, -300)
        XCTAssertEqual(p.backOffset, 0)
        let q = place(.reveal, fromBack: true, 300)
        XCTAssertEqual(q.contentOffset, -500)
        XCTAssertEqual(q.backOffset, 0)
    }

    func testSyncKeepsBackCoverAttachedToDayPageBottom() {
        for offset in stride(from: CGFloat(0), through: h, by: 100) {
            let up = place(.sync, fromBack: false, -offset)
            XCTAssertEqual(up.backOffset - up.contentOffset, h)
            let down = place(.sync, fromBack: true, offset)
            XCTAssertEqual(down.backOffset - down.contentOffset, h)
        }
    }

    func testCommittedEndsMatchDestinationRestInEveryStyle() {
        for t in BackCoverTransition.allCases {
            XCTAssertEqual(place(t, fromBack: false, -h), place(t, fromBack: true, 0))
            XCTAssertEqual(place(t, fromBack: true, h).contentOffset,
                           place(t, fromBack: false, 0).contentOffset)
        }
    }

    func testBackCoverBottomRubberBandFollowsFinger() {
        for t in BackCoverTransition.allCases {
            XCTAssertEqual(place(t, fromBack: true, -40).backOffset, -40)
            XCTAssertEqual(place(t, fromBack: true, -40).contentOffset, -h)
        }
    }
}
