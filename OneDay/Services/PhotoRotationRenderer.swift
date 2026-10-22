import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Serialize full-resolution renders across assets. Per-asset busy flags alone
/// would allow several large decodes to exhaust the process memory together.
actor PhotoRotationRenderWorker {
    static let shared = PhotoRotationRenderWorker()

    func render(inputURL: URL, outputURL: URL, orientation: Int32, outputType: String,
                previousAdjustment: PhotoRotationAdjustment?) throws -> PhotoRotationAdjustment {
        let fingerprint = try PhotoRotationAdjustment.fingerprint(of: inputURL)
        let adjustment = try PhotoRotationAdjustment.next(after: previousAdjustment,
                                                          baselineFingerprint: fingerprint,
                                                          baselineOrientation: orientation)
        try PhotoRotationRenderer.render(inputURL: inputURL, outputURL: outputURL,
                                         orientation: orientation, outputType: outputType,
                                         clockwiseQuarterTurns: adjustment.clockwiseQuarterTurns)
        return adjustment
    }
}

nonisolated enum PhotoRotationError: LocalizedError, Equatable {
    case unsupported, permission, unavailable, changed, baselineChanged, tooLarge, rendering, interrupted, savedButUnavailable, busy

    var errorDescription: String? {
        switch self {
        case .unsupported: return "这张图片的格式或编辑权限暂不支持旋转，原图未改动。"
        case .permission: return "需要照片图库的读写权限才能保存旋转。"
        case .unavailable: return "无法读取图片，请检查网络及 iCloud 下载状态后重试。"
        case .changed: return "图片已在其他地方修改，请重新打开后再旋转。"
        case .baselineChanged: return "系统返回的旋转基准图已变化。为避免损失已有编辑，本次未保存。"
        case .tooLarge: return "图片超出安全处理范围，未压缩尺寸，也未修改原图。"
        case .rendering: return "无法完整保留这张图片的内容，未保存旋转。"
        case .interrupted: return "旋转保存已中断，原图未改动，请重试。"
        case .savedButUnavailable: return "旋转已保存，但暂时无法重新读取图片，请重新打开图库。"
        case .busy: return "这张照片正在保存旋转，请稍后再试。"
        }
    }
}

/// Runs off the main actor. No thumbnail decode, resampling or screen-sized export.
nonisolated enum PhotoRotationRenderer {
    static func render(inputURL: URL, outputURL: URL, orientation: Int32,
                       outputType: String, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                       clockwiseQuarterTurns: Int = 1) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let composedOrientation = PhotoRotationPolicy.rotatedOrientation(orientation, clockwiseQuarterTurns: clockwiseQuarterTurns),
                  let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
                  CGImageSourceGetCount(source) == 1,
                  let typeID = CGImageSourceGetType(source) as String?,
                  let type = UTType(typeID),
                  [UTType.jpeg, .png, .heic, .tiff].contains(where: { type.conforms(to: $0) }),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                throw PhotoRotationError.unsupported
            }
            guard PhotoRotationPolicy.fitsMemoryBudget(width: width, height: height, physicalMemory: physicalMemory) else {
                throw PhotoRotationError.tooLarge
            }
            // Do not discard gain maps, portrait auxiliaries or high-bit-depth data.
            var auxiliaryTypes = [
                kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeHDRGainMap,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte
            ]
            if #available(macOS 15, iOS 18, *) {
                auxiliaryTypes.append(kCGImageAuxiliaryDataTypeISOGainMap)
            }
            guard (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
                  !auxiliaryTypes.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary),
                  decoded.bitsPerComponent <= 8,
                  let colorSpace = decoded.colorSpace,
                  colorSpace.model == .rgb || colorSpace.model == .monochrome,
                  !CGColorSpaceUsesExtendedRange(colorSpace), !colorSpace.isHDR() else {
                throw PhotoRotationError.unsupported
            }
            let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool ?? false)
                || [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(decoded.alphaInfo)
            guard !hasAlpha || outputType == UTType.png.identifier else {
                throw PhotoRotationError.unsupported
            }
            try Task.checkCancellation()
            let targetColorSpace = colorSpace.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            let rotated = CIImage(cgImage: decoded).oriented(forExifOrientation: composedOrientation)
            guard let image = context.createCGImage(rotated, from: rotated.extent,
                                                    format: .RGBA8, colorSpace: targetColorSpace),
                  let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, outputType as CFString, 1, nil) else {
                throw PhotoRotationError.rendering
            }
            // Preserve capture metadata, but never copy an embedded thumbnail
            // or stale orientation/dimensions into the newly rendered file.
            var outputProperties: [CFString: Any] = [
                kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: 1.0
            ]
            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            outputProperties[kCGImagePropertyExifDictionary] = exif
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFOrientation] = 1
            outputProperties[kCGImagePropertyTIFFDictionary] = tiff
            for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary] {
                outputProperties[key] = properties[key]
            }
            CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PhotoRotationError.rendering }
            try Task.checkCancellation()
        }
    }
}
