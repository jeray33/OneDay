import XCTest
import CoreGraphics
@testable import MediaFilter

final class PhotoRotationAdjustmentTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)

    func testCumulativeTurnsSurviveReloadAndWrapWithoutChangingBaseline() throws {
        for orientation in Int32(1)...8 {
            var previous: PhotoRotationAdjustment?
            for step in 1...32 {
                let next = try PhotoRotationAdjustment.next(after: previous, baselineFingerprint: fingerprint,
                                                            baselineOrientation: orientation)
                XCTAssertEqual(next.clockwiseQuarterTurns, step % 4)
                XCTAssertEqual(next.baselineFingerprint, fingerprint)
                XCTAssertEqual(next.baselineOrientation, orientation)
                previous = try XCTUnwrap(decode(try next.encoded()))
            }
        }
    }

    func testLegacyForeignFutureAndDamagedRecipesCannotClaimAnUnadjustedBase() throws {
        let valid = try PhotoRotationAdjustment.next(after: nil, baselineFingerprint: fingerprint,
                                                     baselineOrientation: 1).encoded()
        XCTAssertNotNil(decode(valid))
        XCTAssertNil(decode(valid, version: "1"))
        XCTAssertNil(decode(valid, version: "3"))
        XCTAssertNil(decode(valid, identifier: "another.editor"))
        XCTAssertNil(decode(Data("not json".utf8)))
        for (turns, orientation, hash) in [
            (-1, 1, fingerprint), (4, 1, fingerprint), (1, 0, fingerprint),
            (1, 9, fingerprint), (1, 1, "bad"), (1, 1, String(repeating: "g", count: 64))
        ] {
            let data = try PhotoRotationAdjustment(clockwiseQuarterTurns: turns, baselineFingerprint: hash,
                                                   baselineOrientation: Int32(orientation)).encoded()
            XCTAssertNil(decode(data))
        }
    }

    func testDifferentBaseOrOrientationFailsInsteadOfFlatteningAnotherOutput() throws {
        let previous = try PhotoRotationAdjustment.next(after: nil, baselineFingerprint: fingerprint, baselineOrientation: 6)
        XCTAssertThrowsError(try PhotoRotationAdjustment.next(
            after: previous, baselineFingerprint: String(repeating: "b", count: 64), baselineOrientation: 6
        )) { XCTAssertEqual($0 as? PhotoRotationError, .baselineChanged) }
        XCTAssertThrowsError(try PhotoRotationAdjustment.next(
            after: previous, baselineFingerprint: fingerprint, baselineOrientation: 1
        )) { XCTAssertEqual($0 as? PhotoRotationError, .baselineChanged) }
    }

    func testCumulativeOrientationCompositionMatchesRepeatedClockwiseTurns() throws {
        for orientation in Int32(1)...8 {
            var expected = orientation
            for turns in 0...3 {
                XCTAssertEqual(PhotoRotationPolicy.rotatedOrientation(orientation, clockwiseQuarterTurns: turns), expected)
                expected = try XCTUnwrap(PhotoRotationPolicy.clockwiseOrientation(expected))
            }
        }
        XCTAssertNil(PhotoRotationPolicy.rotatedOrientation(0, clockwiseQuarterTurns: 0))
        XCTAssertNil(PhotoRotationPolicy.rotatedOrientation(1, clockwiseQuarterTurns: -1))
        XCTAssertNil(PhotoRotationPolicy.rotatedOrientation(1, clockwiseQuarterTurns: 4))
    }

    func testFrameAndImageUseOneProgressThroughTheEntireTurn() {
        let from = CGSize(width: 200, height: 400)
        let to = CGSize(width: 360, height: 180)
        XCTAssertEqual(PhotoRotationPolicy.interpolatedCardSize(from: from, to: to, progress: 0), from)
        XCTAssertEqual(PhotoRotationPolicy.interpolatedCardSize(from: from, to: to, progress: 1), to)
        for step in 0...100 {
            let progress = Double(step) / 100
            let card = PhotoRotationPolicy.interpolatedCardSize(from: from, to: to, progress: progress)
            XCTAssertEqual((card.width - from.width) / (to.width - from.width), progress, accuracy: 0.000001)
            XCTAssertEqual((card.height - from.height) / (to.height - from.height), progress, accuracy: 0.000001)
            let source = CGSize(width: 2, height: 4)
            let layout = PhotoRotationPolicy.rotatingCardLayout(
                viewport: card, imageAspect: source.width / source.height,
                sideBorder: 0, bottomBorder: 0, progress: progress)
            let angle = progress * .pi / 2
            let cosine = CGFloat(cos(angle))
            let sine = CGFloat(sin(angle))
            let rotatedWidth = layout.cardSize.width * cosine + layout.cardSize.height * sine
            let rotatedHeight = layout.cardSize.width * sine + layout.cardSize.height * cosine
            XCTAssertLessThanOrEqual(rotatedWidth, card.width + 0.000001)
            XCTAssertLessThanOrEqual(rotatedHeight, card.height + 0.000001)
        }
    }

    private func decode(_ data: Data, identifier: String = PhotoRotationAdjustment.formatIdentifier,
                        version: String = PhotoRotationAdjustment.formatVersion) -> PhotoRotationAdjustment? {
        PhotoRotationAdjustment.decode(formatIdentifier: identifier, formatVersion: version, data: data)
    }
}
