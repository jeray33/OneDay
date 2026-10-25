import AVFoundation
import CryptoKit

/// Exact, local-only compressed content, not a perceptual similarity score.
/// Unknown formats, incomplete reads and unsupported playback arrangements fail
/// closed. Container creation dates and Photos identifiers are not content.
nonisolated enum VideoContentFingerprint {
    static func digest(_ asset: AVAsset, deadline: Date) async -> String? {
        guard available(deadline), let file = asset as? AVURLAsset, file.url.isFileURL else { return nil }
        do {
            let (tracks, duration, rate, volume, protected) = try await asset.load(
                .tracks, .duration, .preferredRate, .preferredVolume, .hasProtectedContent)
            guard available(deadline), !protected, duration.isNumeric, duration.seconds > 0,
                  tracks.filter({ $0.mediaType == .video }).count == 1,
                  tracks.filter({ $0.mediaType == .audio }).count <= 1,
                  tracks.allSatisfy({ $0.mediaType == .video || $0.mediaType == .audio }) else { return nil }
            var result = Accumulator()
            result.text("video-content-v1")
            result.time(duration)
            guard result.property(rate), result.property(volume) else { return nil }
            var digests: [String] = []
            for track in tracks {
                guard let digest = try await trackDigest(asset, track: track, deadline: deadline) else { return nil }
                digests.append(digest)
            }
            // Track IDs and interleaving order are container details. With at
            // most one track of each type, sorting cannot mask track selection.
            for digest in digests.sorted() { result.text(digest) }
            return available(deadline) ? result.finish() : nil
        } catch { return nil }
    }

    private static func trackDigest(
        _ asset: AVAsset, track: AVAssetTrack, deadline: Date
    ) async throws -> String? {
        let (range, transform, size, volume, enabled) = try await track.load(
            .timeRange, .preferredTransform, .naturalSize, .preferredVolume, .isEnabled)
        let (selfContained, segments) = try await track.load(.isSelfContained, .segments)
        guard available(deadline), selfContained,
              range.start.isNumeric, range.duration.isNumeric, range.duration.seconds > 0 else { return nil }
        var hash = Accumulator()
        hash.text(track.mediaType.rawValue)
        hash.time(range.start)
        hash.time(range.duration)
        guard hash.property([transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]),
              hash.property([size.width, size.height]), hash.property(volume), hash.property(enabled) else { return nil }
        hash.text("\(segments.count)")
        for segment in segments {
            hash.text(segment.isEmpty ? "empty" : "media")
            let mapping = segment.timeMapping
            for time in [mapping.source.start, mapping.source.duration, mapping.target.start, mapping.target.duration] {
                hash.time(time)
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var payloadBytes = 0
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            guard available(deadline), CMSampleBufferDataIsReady(sample) else { return nil }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count >= 0 else { return nil }
            // Zero-sample buffers carry edit/trim markers. Preserve their
            // timing and attachments, but do not require a nonexistent payload.
            hash.text("buffer:\(count)")
            guard hash.sampleMetadata(sample) else { return nil }
            if count == 0 { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  hash.format(format),
                  CMSampleBufferGetImageBuffer(sample) == nil,
                  let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { return nil }
            hash.text("payload:\(length)")
            var offset = 0
            while offset < length {
                guard available(deadline) else { return nil }
                let chunk = min(1_048_576, length - offset)
                var data = Data(count: chunk)
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: chunk, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { return nil }
                hash.bytes(data)
                offset += chunk
            }
            payloadBytes += length
            sampleCount += count
        }
        guard available(deadline), reader.status == .completed,
              reader.error == nil, payloadBytes > 0, sampleCount > 0 else { return nil }
        return hash.finish()
    }

    private static func available(_ deadline: Date) -> Bool {
        !Task.isCancelled && Date() < deadline
    }

    /// Length-prefixed, deterministic encoding. Unknown attachment values are
    /// rejected rather than silently dropping potentially meaningful edits.
    struct Accumulator {
        private var hash = SHA256()

        mutating func bytes(_ data: Data) { hash.update(data: data) }

        mutating func text(_ text: String) {
            let data = Data(text.utf8)
            var count = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
            bytes(data)
        }

        mutating func time(_ time: CMTime) {
            if time.isNumeric, time.timescale > 0 {
                var a = time.value.magnitude
                var b = UInt64(time.timescale)
                while b != 0 { (a, b) = (b, a % b) }
                let divisor = Int64(max(1, a))
                text("time:\(time.value / divisor)/\(Int64(time.timescale) / divisor)@\(time.epoch)")
            } else {
                text("time-flags:\(time.flags.rawValue)@\(time.epoch)")
            }
        }

        mutating func property(_ value: Any) -> Bool {
            if let data = value as? Data {
                text("data:\(data.count)"); bytes(data)
            } else if let dictionary = value as? [String: Any] {
                text("dictionary:\(dictionary.count)")
                for key in dictionary.keys.sorted() {
                    text(key)
                    guard property(dictionary[key]!) else { return false }
                }
            } else if let array = value as? [Any] {
                text("array:\(array.count)")
                for element in array { guard property(element) else { return false } }
            } else if let string = value as? String {
                text("string"); text(string)
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { return false }
                text("number:\(String(cString: number.objCType)):\(number.stringValue)")
            } else { return false }
            return true
        }

        mutating func format(_ format: CMFormatDescription) -> Bool {
            let mediaType = CMFormatDescriptionGetMediaType(format)
            text("format:\(mediaType):\(CMFormatDescriptionGetMediaSubType(format))")
            guard property(CMFormatDescriptionGetExtensions(format)) else { return false }
            if mediaType == kCMMediaType_Video {
                let size = CMVideoFormatDescriptionGetDimensions(format)
                text("dimensions:\(size.width)x\(size.height)")
            } else if mediaType == kCMMediaType_Audio {
                guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return false }
                let stream = description.pointee
                guard property(stream.mSampleRate) else { return false }
                text("audio:\(stream.mFormatID):\(stream.mFormatFlags):\(stream.mBytesPerPacket):\(stream.mFramesPerPacket):\(stream.mBytesPerFrame):\(stream.mChannelsPerFrame):\(stream.mBitsPerChannel)")
                var count = 0
                let cookie = CMAudioFormatDescriptionGetMagicCookie(format, sizeOut: &count)
                text("cookie:\(count)")
                if count > 0 {
                    guard let cookie else { return false }
                    bytes(Data(bytes: cookie, count: count))
                }
                let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &count)
                text("layout:\(count)")
                if count > 0 {
                    guard let layout else { return false }
                    bytes(Data(bytes: layout, count: count))
                }
            } else { return false }
            return true
        }

        private mutating func sampleLayout(_ sample: CMSampleBuffer) -> Bool {
            var timingCount = 0
            guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                        entriesNeededOut: &timingCount) == noErr else { return false }
            var timings = [CMSampleTimingInfo](repeating: .init(), count: timingCount)
            let timingStatus = timings.withUnsafeMutableBufferPointer {
                CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingCount, arrayToFill: $0.baseAddress,
                                                      entriesNeededOut: nil)
            }
            guard timingStatus == noErr else { return false }
            text("timings:\(timingCount)")
            for timing in timings {
                time(timing.presentationTimeStamp); time(timing.decodeTimeStamp); time(timing.duration)
            }
            var sizeCount = 0
            guard CMSampleBufferGetSampleSizeArray(sample, entryCount: 0, arrayToFill: nil,
                                                  entriesNeededOut: &sizeCount) == noErr else { return false }
            var sizes = [Int](repeating: 0, count: sizeCount)
            let sizeStatus = sizes.withUnsafeMutableBufferPointer {
                CMSampleBufferGetSampleSizeArray(sample, entryCount: sizeCount, arrayToFill: $0.baseAddress,
                                                entriesNeededOut: nil)
            }
            guard sizeStatus == noErr else { return false }
            text("sizes:\(sizeCount)")
            for size in sizes { text("\(size)") }
            return true
        }

        mutating func sampleMetadata(_ sample: CMSampleBuffer) -> Bool {
            if CMSampleBufferGetNumSamples(sample) == 0 {
                time(CMSampleBufferGetPresentationTimeStamp(sample))
                time(CMSampleBufferGetDecodeTimeStamp(sample))
                time(CMSampleBufferGetDuration(sample))
            } else {
                guard sampleLayout(sample) else { return false }
            }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) {
                text("sample-attachments")
                guard property(attachments) else { return false }
            } else { text("no-sample-attachments") }
            for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
                if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault,
                                                                  target: sample, attachmentMode: mode) {
                    text("buffer-attachments:\(mode)")
                    guard property(attachments) else { return false }
                } else { text("no-buffer-attachments:\(mode)") }
            }
            return true
        }

        mutating func finish() -> String {
            hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
