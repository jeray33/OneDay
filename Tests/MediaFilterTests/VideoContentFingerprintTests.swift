import XCTest
import AVFoundation
import CryptoKit
@testable import MediaFilter

final class VideoContentFingerprintTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func digest(_ url: URL, deadline: Date = Date().addingTimeInterval(20)) async -> String? {
        await VideoContentFingerprint.digest(AVURLAsset(url: url), deadline: deadline)
    }

    func testContainerCreationDateDoesNotChangeContentFingerprint() async throws {
        let original = try await movie(audio: 1_000)
        let copy = directory.appendingPathComponent("container-copy.mov")
        var data = try Data(contentsOf: original)
        let oldHash = SHA256.hash(data: data)
        let mvhd = try XCTUnwrap(data.range(of: Data("mvhd".utf8)))
        // Full-box header is version/flags (4 bytes), then creation time.
        data[mvhd.upperBound + 4] ^= 1
        XCTAssertNotEqual(oldHash, SHA256.hash(data: data))
        try data.write(to: copy)
        let left = await digest(original)
        let right = await digest(copy)
        XCTAssertNotNil(left)
        XCTAssertEqual(left, right)
    }

    func testDifferentLastFrameStaysDistinct() async throws {
        let original = try await movie()
        let changed = try await movie(lastFrame: 220)
        let left = await digest(original)
        let right = await digest(changed)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left, right)
    }

    func testDifferentAudioStaysDistinct() async throws {
        let original = try await movie(audio: 1_000)
        let changed = try await movie(audio: 2_000)
        let left = await digest(original)
        let right = await digest(changed)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left, right)
    }

    func testMissingAudioStaysDistinct() async throws {
        let original = try await movie(audio: 1_000)
        let silent = try await movie()
        let left = await digest(original)
        let right = await digest(silent)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left, right)
    }

    func testOrientationIsPartOfPlayback() async throws {
        let original = try await movie()
        let rotated = try await movie(transform: CGAffineTransform(rotationAngle: .pi / 2))
        let left = await digest(original)
        let right = await digest(rotated)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left, right)
    }

    func testTimingIsPartOfPlayback() async throws {
        let original = try await movie()
        let slower = try await movie(timescale: 15)
        let left = await digest(original)
        let right = await digest(slower)
        XCTAssertNotNil(left)
        XCTAssertNotNil(right)
        XCTAssertNotEqual(left, right)
    }

    func testExpiredDeadlineMissingAndTruncatedFilesCannotConfirmContent() async throws {
        let original = try await movie()
        let expired = await digest(original, deadline: .distantPast)
        XCTAssertNil(expired)
        let missing = await digest(directory.appendingPathComponent("missing.mov"))
        XCTAssertNil(missing)
        let truncated = directory.appendingPathComponent("truncated.mov")
        try Data(contentsOf: original).prefix(32).write(to: truncated)
        let incomplete = await digest(truncated)
        XCTAssertNil(incomplete)
    }

    func testCancelledReaderCannotConfirmContent() async throws {
        let url = try await movie()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.digest(url)
        }
        let result = await task.value
        XCTAssertNil(result)
    }

    func testNonFileCompositionsAreNotCompared() async {
        let result = await VideoContentFingerprint.digest(
            AVMutableComposition(), deadline: Date().addingTimeInterval(5))
        XCTAssertNil(result)
    }

    func testRemoteURLsAreRejectedWithoutOpeningMedia() async {
        let asset = AVURLAsset(url: URL(string: "https://invalid.example/never-download.mov")!)
        let result = await VideoContentFingerprint.digest(asset, deadline: Date().addingTimeInterval(5))
        XCTAssertNil(result)
    }

    func testCanonicalMetadataAndTimes() {
        var a = VideoContentFingerprint.Accumulator()
        var b = VideoContentFingerprint.Accumulator()
        XCTAssertTrue(a.property(["b": Data([1, 2]), "a": 42]))
        XCTAssertTrue(b.property(["a": 42, "b": Data([1, 2])]))
        a.time(CMTime(value: 1, timescale: 30))
        b.time(CMTime(value: 2, timescale: 60))
        XCTAssertEqual(a.finish(), b.finish())
        var unsupported = VideoContentFingerprint.Accumulator()
        XCTAssertFalse(unsupported.property(URL(fileURLWithPath: "/unsupported")))
        XCTAssertFalse(unsupported.property(Double.nan))
    }

    func testZeroSampleEditMarkerRetainsTrimMetadataWithoutRequiringPayload() throws {
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let marker = try XCTUnwrap(sample)
        var a = VideoContentFingerprint.Accumulator()
        XCTAssertTrue(a.sampleMetadata(marker))
        CMSetAttachment(marker, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                        value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 30), allocator: kCFAllocatorDefault),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        var b = VideoContentFingerprint.Accumulator()
        XCTAssertTrue(b.sampleMetadata(marker))
        XCTAssertNotEqual(a.finish(), b.finish())
    }

    private func movie(
        lastFrame: UInt8 = 30, audio: Int16? = nil,
        transform: CGAffineTransform = .identity, timescale: Int32 = 30
    ) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        writer.add(input)
        let audioInput = audio.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: nil) }
        if let audioInput { writer.add(audioInput) }
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var image: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
                                              nil, &image), kCVReturnSuccess)
            let pixels = try XCTUnwrap(image)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels)!, Int32(frame == 2 ? lastFrame : 30),
                   CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: timescale)))
        }
        input.markAsFinished()
        if let audioInput, let audio {
            XCTAssertTrue(audioInput.append(try audioSample(audio)))
            audioInput.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: timescale))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private func audioSample(_ value: Int16) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let data = [Int16](repeating: value, count: 4_800).withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format,
            sampleCount: 4_800, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
