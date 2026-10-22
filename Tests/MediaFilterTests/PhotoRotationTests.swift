import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MediaFilter

final class PhotoRotationTests: XCTestCase {
    private var eligible: PhotoRotationPolicy.Input {
        .init(isStillImage: true, isLivePhoto: false, isAnimated: false, isRAW: false,
              isHDR: false, isForeignShared: false, systemAllowsContentEditing: true,
              hasSupportedResources: true)
    }

    func testStaticPhotosScreenshotsLongImagesAndPanoramasShareTheSamePolicy() {
        XCTAssertTrue(PhotoRotationPolicy.allows(eligible))
        for size in [CGSize(width: 4000, height: 3000), CGSize(width: 1170, height: 2532),
                     CGSize(width: 600, height: 20000), CGSize(width: 16000, height: 1000)] {
            XCTAssertTrue(PhotoRotationPolicy.fitsMemoryBudget(
                width: Int(size.width), height: Int(size.height), physicalMemory: 8_589_934_592))
        }
    }

    func testEveryExcludedMediaTypeAndPermissionIndependentlyHidesRotation() {
        let excluded: [(inout PhotoRotationPolicy.Input) -> Void] = [
            { $0.isStillImage = false }, { $0.isLivePhoto = true },
            { $0.isAnimated = true }, { $0.isRAW = true }, { $0.isHDR = true },
            { $0.isForeignShared = true }, { $0.systemAllowsContentEditing = false },
            { $0.hasSupportedResources = false }
        ]
        for exclusion in excluded {
            var input = eligible
            exclusion(&input)
            XCTAssertFalse(PhotoRotationPolicy.allows(input))
        }
    }

    func testMemoryBudgetRejectsInvalidHugeAndOverflowingInputs() {
        for size in [(0, 10), (10, -1), (Int.max, Int.max), (50000, 50000)] {
            XCTAssertFalse(PhotoRotationPolicy.fitsMemoryBudget(
                width: size.0, height: size.1, physicalMemory: 8_589_934_592))
        }
        XCTAssertFalse(PhotoRotationPolicy.fitsMemoryBudget(width: 1, height: 1, physicalMemory: 0))
    }

    func testFourClockwiseTurnsRestoreAllEightEXIFOrientationsWithoutReverseWrap() throws {
        for original in Int32(1)...8 {
            var current = original
            for _ in 0..<4 { current = try XCTUnwrap(PhotoRotationPolicy.clockwiseOrientation(current)) }
            XCTAssertEqual(current, original)
        }
        XCTAssertNil(PhotoRotationPolicy.clockwiseOrientation(0))
        XCTAssertNil(PhotoRotationPolicy.clockwiseOrientation(9))
    }

    func testEntireFramedCardFitsAtEveryAngleForExtremeAspects() {
        for source in [CGSize(width: 2, height: 100), CGSize(width: 100, height: 2),
                       CGSize(width: 4, height: 3), CGSize(width: 1, height: 1)] {
            let viewport = CGSize(width: 320, height: 440)
            for (side, bottom): (CGFloat, CGFloat) in [(0, 0), (8, 8), (12, 58)] {
                for step in 0...90 {
                    let progress = Double(step) / 90
                    let layout = PhotoRotationPolicy.rotatingCardLayout(
                        viewport: viewport, imageAspect: source.width / source.height,
                        sideBorder: side, bottomBorder: bottom, progress: progress)
                    let c = CGFloat(cos(progress * .pi / 2))
                    let s = CGFloat(sin(progress * .pi / 2))
                    let rotatedWidth = layout.cardSize.width * c + layout.cardSize.height * s
                    let rotatedHeight = layout.cardSize.width * s + layout.cardSize.height * c
                    XCTAssertLessThanOrEqual(rotatedWidth, viewport.width + 0.001)
                    XCTAssertLessThanOrEqual(rotatedHeight, viewport.height + 0.001)
                    XCTAssertEqual(layout.imageSize.width / layout.imageSize.height,
                                   source.width / source.height, accuracy: 0.00001)
                }
            }
        }
        XCTAssertEqual(PhotoRotationPolicy.rotatingCardLayout(
            viewport: .zero, imageAspect: 1, sideBorder: 12, bottomBorder: 58, progress: 0
        ).cardSize, .zero)
    }

    func testWholeCardStartsAndEndsAtTheSameGeometryAsTheZoomablePhoto() {
        func card(aspect: CGFloat, side: CGFloat, bottom: CGFloat) -> CGSize {
            let width = min(340 - side * 2, (480 - side - bottom) * aspect)
            return CGSize(width: width + side * 2, height: width / aspect + side + bottom)
        }
        for aspect: CGFloat in [0.02, 3.0 / 4, 1, 4.0 / 3, 12] {
            for (side, bottom): (CGFloat, CGFloat) in [(0, 0), (8, 8), (12, 58)] {
                let from = card(aspect: aspect, side: side, bottom: bottom)
                let to = card(aspect: 1 / aspect, side: side, bottom: bottom)
                let start = PhotoRotationPolicy.rotatingCardLayout(
                    viewport: from, imageAspect: aspect, sideBorder: side, bottomBorder: bottom, progress: 0)
                let end = PhotoRotationPolicy.rotatingCardLayout(
                    viewport: to, imageAspect: aspect, sideBorder: side, bottomBorder: bottom, progress: 1)
                XCTAssertEqual(start.cardSize.width, from.width, accuracy: 0.000001)
                XCTAssertEqual(start.cardSize.height, from.height, accuracy: 0.000001)
                XCTAssertEqual(end.cardSize.height, to.width, accuracy: 0.000001)
                XCTAssertEqual(end.cardSize.width, to.height, accuracy: 0.000001)
                XCTAssertEqual(start.bottomBorder, bottom)
                XCTAssertEqual(start.trailingBorder, side)
                // Trailing rotates into the final bottom, including Polaroid.
                XCTAssertEqual(end.trailingBorder, bottom)
                XCTAssertEqual(end.bottomBorder, side)
            }
        }
    }

    func testSmallBadgeIsAnchoredInsideActualPixelsNotThePolaroidStrip() {
        for image in [CGRect(x: 12, y: 12, width: 300, height: 440),
                      CGRect(x: 12, y: 12, width: 4, height: 440),
                      CGRect(x: 12, y: 12, width: 300, height: 5)] {
            let layout = PhotoRotationPolicy.rotationBadgeLayout(in: image)
            let half = 11 * layout.scale
            XCTAssertGreaterThanOrEqual(layout.center.x - half + 0.000001, image.minX)
            XCTAssertLessThanOrEqual(layout.center.x + half, image.maxX + 0.000001)
            XCTAssertGreaterThanOrEqual(layout.center.y - half + 0.000001, image.minY)
            XCTAssertLessThanOrEqual(layout.center.y + half, image.maxY + 0.000001)
            XCTAssertGreaterThan(layout.scale, 0)
            XCTAssertLessThanOrEqual(layout.scale, 1)
        }
        let regular = PhotoRotationPolicy.rotationBadgeLayout(in: CGRect(x: 12, y: 12, width: 300, height: 440))
        XCTAssertEqual(regular.center, CGPoint(x: 293, y: 433))
        XCTAssertEqual(regular.scale, 1)
    }

    func testRotationControlOnlyAppearsAtSettledDefaultZoom() {
        XCTAssertTrue(PhotoRotationPolicy.isRestingAtDefaultScale(
            zoomScale: 1, minimumZoomScale: 1, isZooming: false, isZoomBouncing: false, isTransitioning: false))
        for scale: CGFloat in [0.5, 0.98, 1.02, 2.5, 4, .nan, .infinity] {
            XCTAssertFalse(PhotoRotationPolicy.isRestingAtDefaultScale(
                zoomScale: scale, minimumZoomScale: 1,
                isZooming: false, isZoomBouncing: false, isTransitioning: false))
        }
        for (zooming, bouncing, transitioning) in [
            (true, false, false), (false, true, false), (false, false, true), (true, true, true)
        ] {
            // Even at scale 1, a starting pinch / ending bounce / animated
            // double tap is not the resting default state.
            XCTAssertFalse(PhotoRotationPolicy.isRestingAtDefaultScale(
                zoomScale: 1, minimumZoomScale: 1,
                isZooming: zooming, isZoomBouncing: bouncing, isTransitioning: transitioning))
        }
        XCTAssertFalse(PhotoRotationPolicy.isRestingAtDefaultScale(
            zoomScale: 0, minimumZoomScale: 0, isZooming: false, isZoomBouncing: false, isTransitioning: false))
    }

    func testRenderedPixelsRotateClockwiseForAllEightEXIFOrientations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.png")
        // Six distinct grayscale pixels, in top-to-bottom row order.
        let bytes: [UInt8] = [20, 60, 100, 140, 180, 220].flatMap { [$0, $0, $0, 255] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05",
                kCGImagePropertyExifPixelXDimension: 2, kCGImagePropertyExifPixelYDimension: 3
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test camera"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let expected: [[UInt8]] = [
            [180, 100, 20, 220, 140, 60], [220, 140, 60, 180, 100, 20],
            [60, 140, 220, 20, 100, 180], [20, 100, 180, 60, 140, 220],
            [60, 20, 140, 100, 220, 180], [220, 180, 140, 100, 60, 20],
            [180, 220, 100, 140, 20, 60], [20, 60, 100, 140, 180, 220]
        ]
        for orientation in Int32(1)...8 {
            let output = directory.appendingPathComponent("output-\(orientation).png")
            try PhotoRotationRenderer.render(inputURL: input, outputURL: output,
                                             orientation: orientation, outputType: UTType.png.identifier)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let rotated = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(rotated.width, orientation <= 4 ? 3 : 2)
            XCTAssertEqual(rotated.height, orientation <= 4 ? 2 : 3)
            let pixels = try renderedBytes(rotated)
            let grayscale = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
            for (actual, expected) in zip(grayscale, expected[Int(orientation - 1)]) {
                XCTAssertEqual(Int(actual), Int(expected), accuracy: 1, "EXIF \(orientation)")
            }
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:01:02 03:04:05")
            XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, rotated.width)
            XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension] as? Int, rotated.height)
        }
    }

    func testTransparencyCannotBeSilentlyFlattenedIntoJPEG() throws {
        try withFixture(alpha: true) { input, output, _ in
            XCTAssertThrowsError(try PhotoRotationRenderer.render(
                inputURL: input, outputURL: output, orientation: 1, outputType: UTType.jpeg.identifier
            )) { XCTAssertEqual($0 as? PhotoRotationError, .unsupported) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            try PhotoRotationRenderer.render(inputURL: input, outputURL: output,
                                             orientation: 1, outputType: UTType.png.identifier)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        }
    }

    func testAnimatedInputAndInvalidOrientationNeverProduceOutput() throws {
        try withFixture(alpha: false) { input, output, image in
            let gif = input.deletingLastPathComponent().appendingPathComponent("animated.gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            for (url, orientation) in [(gif, Int32(1)), (input, Int32(0))] {
                XCTAssertThrowsError(try PhotoRotationRenderer.render(
                    inputURL: url, outputURL: output, orientation: orientation, outputType: UTType.png.identifier
                )) { XCTAssertEqual($0 as? PhotoRotationError, .unsupported) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testBudgetFailureNeverDownsamplesOrWritesOutput() throws {
        try withFixture(alpha: false) { input, output, _ in
            XCTAssertThrowsError(try PhotoRotationRenderer.render(
                inputURL: input, outputURL: output, orientation: 1,
                outputType: UTType.png.identifier, physicalMemory: 1
            )) { XCTAssertEqual($0 as? PhotoRotationError, .tooLarge) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testFourRenderedTurnsRestorePixelsAndDimensions() throws {
        try withFixture(alpha: false) { input, output, original in
            var current = input
            for step in 0..<4 {
                let next = output.appendingPathExtension("\(step).png")
                try PhotoRotationRenderer.render(inputURL: current, outputURL: next,
                                                 orientation: 1, outputType: UTType.png.identifier)
                current = next
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(current as CFURL, nil))
            let rotated = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(rotated.width, 2)
            XCTAssertEqual(rotated.height, 3)
            XCTAssertEqual(try renderedBytes(rotated), try renderedBytes(original))
        }
    }

    func testRepeatedJPEGExportsAlwaysMatchOneExportFromTheSameBaseline() async throws {
        let fixture = try makeFixture(alpha: false)
        defer { try? FileManager.default.removeItem(at: fixture.input.deletingLastPathComponent()) }
        // Start from a JPEG to exercise a genuinely lossy baseline, not only PNG.
        let baseline = fixture.output.appendingPathExtension("baseline.jpeg")
        try PhotoRotationRenderer.render(inputURL: fixture.input, outputURL: baseline, orientation: 1,
                                         outputType: UTType.jpeg.identifier, clockwiseQuarterTurns: 0)
        var previous: PhotoRotationAdjustment?
        for step in 1...12 {
            let output = fixture.output.appendingPathExtension("\(step).jpeg")
            let adjustment = try await PhotoRotationRenderWorker.shared.render(
                inputURL: baseline, outputURL: output, orientation: 1,
                outputType: UTType.jpeg.identifier, previousAdjustment: previous)
            previous = try XCTUnwrap(PhotoRotationAdjustment.decode(
                formatIdentifier: PhotoRotationAdjustment.formatIdentifier,
                formatVersion: PhotoRotationAdjustment.formatVersion, data: adjustment.encoded()))
            let direct = fixture.output.appendingPathExtension("direct-\(step).jpeg")
            try PhotoRotationRenderer.render(inputURL: baseline, outputURL: direct, orientation: 1,
                                             outputType: UTType.jpeg.identifier, clockwiseQuarterTurns: step % 4)
            let actualSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let expectedSource = try XCTUnwrap(CGImageSourceCreateWithURL(direct as CFURL, nil))
            let actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(actualSource, 0, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(expectedSource, 0, nil))
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try renderedBytes(actual), try renderedBytes(expected), "Turn \(step)")
        }
    }

    func testWorkerRefusesToUseTheLastCompressedOutputAsBaseline() async throws {
        let fixture = try makeFixture(alpha: false)
        defer { try? FileManager.default.removeItem(at: fixture.input.deletingLastPathComponent()) }
        let first = fixture.output.appendingPathExtension("first.jpeg")
        let recipe = try await PhotoRotationRenderWorker.shared.render(
            inputURL: fixture.input, outputURL: first, orientation: 1,
            outputType: UTType.jpeg.identifier, previousAdjustment: nil)
        let second = fixture.output.appendingPathExtension("second.jpeg")
        do {
            _ = try await PhotoRotationRenderWorker.shared.render(
                inputURL: first, outputURL: second, orientation: 1,
                outputType: UTType.jpeg.identifier, previousAdjustment: recipe)
            XCTFail("A previous rendered output must not become the recipe's base")
        } catch {
            XCTAssertEqual(error as? PhotoRotationError, .baselineChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    private func renderedBytes(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func withFixture(alpha: Bool, body: (URL, URL, CGImage) throws -> Void) throws {
        let fixture = try makeFixture(alpha: alpha)
        defer { try? FileManager.default.removeItem(at: fixture.input.deletingLastPathComponent()) }
        try body(fixture.input, fixture.output, fixture.image)
    }

    private func makeFixture(alpha: Bool) throws -> (input: URL, output: URL, image: CGImage) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("input.png")
        let output = directory.appendingPathComponent("output.png")
        let bytes: [UInt8] = [20, 60, 100, 140, 180, 220].flatMap { [$0, $0, $0, alpha ? 128 : 255] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (input, output, image)
    }
}
