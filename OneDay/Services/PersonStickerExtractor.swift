import UIKit
import Vision
import CoreImage

/// A cut-out person with a white outline, ready to scatter on the cover.
struct PersonSticker: Identifiable, Hashable {
    /// Stable id: source photo id + instance index.
    let id: String
    let image: UIImage
    let aspectRatio: CGFloat

    static func == (lhs: PersonSticker, rhs: PersonSticker) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Extracts up to `max` distinct person "stickers" from a set of photos using
/// Vision's foreground instance mask, then renders each as a transparent
/// foreground with a soft white outline.
actor PersonStickerExtractor {
    static let shared = PersonStickerExtractor()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Max photos scanned (bounds Vision cost).
    private static let maxPhotosScanned = 10
    /// MSE threshold (0..1 per channel) under which two face fingerprints are
    /// considered the same person.
    private static let samePersonThreshold: Double = 0.035

    func extract(from items: [PhotoItem], max k: Int) async -> [PersonSticker] {
        guard k > 0 else { return [] }
        let candidates = items.prefix(Self.maxPhotosScanned)

        // Gather all person instances across scanned photos.
        var instances: [Instance] = []
        for item in candidates {
            guard let image = await ImageLoader.shared.thumbnail(
                    asset: item.asset, size: CGSize(width: 1280, height: 1280)),
                  let cg = image.cgImage else { continue }
            let faces = detectFaces(cg)
            guard !faces.isEmpty else { continue }   // no people in this photo
            guard let (observation, handler) = instanceMask(for: cg) else { continue }
            for idx in observation.allInstances {
                guard let maskPB = try? observation.generateScaledMaskForImage(
                        forInstances: IndexSet([idx]), from: handler) else { continue }
                let (area, bbox) = maskAreaAndBox(maskPB)
                guard area > 0.004 else { continue } // ignore tiny/false positives
                // Only keep instances that actually contain a detected face,
                // so we ship people rather than random foreground objects.
                guard let face = faceInside(bbox, faces: faces) else { continue }
                let fp: [Double]? = fingerprint(for: cg, face: face)
                instances.append(Instance(
                    itemID: item.id,
                    instanceIndex: idx,
                    sourceCG: cg,
                    maskPB: maskPB,
                    area: area,
                    fingerprint: fp
                ))
            }
        }

        guard !instances.isEmpty else { return [] }

        // Sort by area descending; greedily pick distinct people.
        instances.sort {
            if $0.area != $1.area { return $0.area > $1.area }
            return $0.itemID < $1.itemID
        }

        var picked: [Instance] = []
        for inst in instances {
            if picked.count >= k { break }
            if let fp = inst.fingerprint,
               picked.contains(where: { similar($0.fingerprint, fp) }) {
                continue
            }
            picked.append(inst)
        }

        // Render stickers.
        var stickers: [PersonSticker] = []
        for inst in picked {
            guard let img = renderSticker(source: inst.sourceCG, mask: inst.maskPB) else { continue }
            let ar = img.size.width / max(img.size.height, 1)
            stickers.append(PersonSticker(
                id: "\(inst.itemID)#\(inst.instanceIndex)",
                image: img, aspectRatio: ar))
        }
        return stickers
    }

    // MARK: - Vision requests

    private func instanceMask(for cg: CGImage) -> (VNInstanceMaskObservation, VNImageRequestHandler)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            if let observation = request.results?.first as? VNInstanceMaskObservation {
                return (observation, handler)
            }
        } catch { return nil }
        return nil
    }

    private func detectFaces(_ cg: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            return (request.results as? [VNFaceObservation]) ?? []
        } catch { return [] }
    }

    /// Returns a face whose center lies inside the instance's bounding box
    /// (i.e. this foreground blob is a person), or nil if none.
    private func faceInside(_ instanceBox: CGRect, faces: [VNFaceObservation]) -> VNFaceObservation? {
        let padded = instanceBox.insetBy(dx: -instanceBox.width * 0.03,
                                         dy: -instanceBox.height * 0.03)
        return faces
            .filter { padded.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
            .max { $0.boundingBox.width * $0.boundingBox.height <
                   $1.boundingBox.width * $1.boundingBox.height }
    }

    // MARK: - Mask area + bounding box

    /// Returns (fraction-of-pixels-on, normalized bounding box in Vision's
    /// bottom-left coordinate space) for a single-channel mask pixel buffer.
    private func maskAreaAndBox(_ buffer: CVPixelBuffer) -> (Double, CGRect) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, .zero) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var on: Int = 0
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                if ptr[y * bytesPerRow + x] > 128 {
                    on += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        let area = Double(on) / Double(w * h)
        guard on > 0 else { return (area, .zero) }
        // Pixel buffer is top-left origin; Vision uses bottom-left, normalized.
        let normX = Double(minX) / Double(w)
        let normY = 1.0 - Double(maxY) / Double(h)
        let normW = Double(maxX - minX) / Double(w)
        let normH = Double(maxY - minY) / Double(h)
        return (area, CGRect(x: normX, y: normY, width: normW, height: normH))
    }

    // MARK: - Face fingerprint

    private func fingerprint(for cg: CGImage, face: VNFaceObservation) -> [Double]? {
        let bbox = VNImageRectForNormalizedRect(face.boundingBox,
                                                 Int(cg.width), Int(cg.height))
        guard bbox.width > 4, bbox.height > 4 else { return nil }
        guard let cropped = cg.cropping(to: bbox) else { return nil }
        let ui = UIImage(cgImage: cropped)
        let small = resizeGrayscale(ui, size: 48)
        guard let data = small else { return nil }
        return data
    }

    private func resizeGrayscale(_ image: UIImage, size: Int) -> [Double]? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let drawn = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        guard let cg = drawn.cgImage,
              let dataProvider = cg.dataProvider,
              let data = dataProvider.data else { return nil }
        let ptr = CFDataGetBytePtr(data)
        let count = CFDataGetLength(data)
        guard count > 0, let ptr else { return nil }
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in stride(from: 0, to: count, by: 4) {
            // luminance approximation
            let r = Double(ptr[i]) / 255.0
            let g = Double(ptr[i + 1]) / 255.0
            let b = Double(ptr[i + 2]) / 255.0
            out.append(0.299 * r + 0.587 * g + 0.114 * b)
        }
        return out
    }

    private func similar(_ a: [Double]?, _ b: [Double]?) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        var sum: Double = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        let mse = sum / Double(a.count)
        return mse < Self.samePersonThreshold
    }

    // MARK: - Sticker rendering (cutout + white outline)

    private func renderSticker(source: CGImage, mask: CVPixelBuffer) -> UIImage? {
        let sourceCI = CIImage(cgImage: source)
        let maskCI = CIImage(cvPixelBuffer: mask)
        // Align mask to source extent (mask may be smaller/larger).
        let maskScaled = maskCI.transformed(by: CGAffineTransform(
            scaleX: sourceCI.extent.width / maskCI.extent.width,
            y: sourceCI.extent.height / maskCI.extent.height))

        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: sourceCI.extent)

        // Person cutout (transparent background).
        let person = sourceCI.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputMaskImageKey: maskScaled,
                         kCIInputBackgroundImageKey: transparent])

        // Dilated mask for the outline ring (wider = thicker white sticker edge).
        let outlineRadius: Double = max(sourceCI.extent.width, sourceCI.extent.height) * 0.035
        let dilated = maskScaled.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [kCIInputRadiusKey: outlineRadius])
        let invertedMask = maskScaled.applyingFilter("CIColorInvert")
        // ringAlpha = dilated * (1 - mask): 1 only in the ring band.
        let ringAlpha = dilated.applyingFilter(
            "CIMultiplyCompositing",
            parameters: [kCIInputBackgroundImageKey: invertedMask])

        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: sourceCI.extent)
        let ring = white.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputMaskImageKey: ringAlpha,
                         kCIInputBackgroundImageKey: transparent])

        // Person on top of the white ring.
        let combined = person.composited(over: ring)

        // Crop to the dilated bounding box so we don't ship a huge transparent canvas.
        let cropped = combined.cropped(to: dilated.extent)
        guard let cg = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: - Instance record

    private struct Instance {
        let itemID: String
        let instanceIndex: Int
        let sourceCG: CGImage
        let maskPB: CVPixelBuffer
        let area: Double
        let fingerprint: [Double]?
    }
}
