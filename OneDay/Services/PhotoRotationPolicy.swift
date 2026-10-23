import Foundation
import CoreGraphics

/// Kept independent of PhotoKit so the exclusions and memory limits are testable.
nonisolated enum PhotoRotationPolicy {
    struct Input {
        var isStillImage: Bool
        var isLivePhoto: Bool
        var isAnimated: Bool
        var isRAW: Bool
        var isHDR: Bool
        var isForeignShared: Bool
        var systemAllowsContentEditing: Bool
        var hasSupportedResources: Bool
    }

    static func allows(_ input: Input) -> Bool {
        input.isStillImage && !input.isLivePhoto && !input.isAnimated
            && !input.isRAW && !input.isHDR && !input.isForeignShared
            && input.systemAllowsContentEditing && input.hasSupportedResources
    }

    static func fitsMemoryBudget(width: Int, height: Int, physicalMemory: UInt64) -> Bool {
        guard width > 0, height > 0 else { return false }
        // Allow for decoding, rendering and encoding, not just the final bitmap.
        let limit = min(UInt64(40_000_000), physicalMemory / 256)
        return UInt64(width) <= limit / UInt64(height)
    }

    /// EXIF composition, including mirrored orientations. Useful when checking
    /// that a clockwise turn is relative to the displayed image, not raw pixels.
    static func clockwiseOrientation(_ orientation: Int32) -> Int32? {
        switch orientation {
        case 1: return 6
        case 2: return 7
        case 3: return 8
        case 4: return 5
        case 5: return 2
        case 6: return 3
        case 7: return 4
        case 8: return 1
        default: return nil
        }
    }

    static func rotatedOrientation(_ orientation: Int32, clockwiseQuarterTurns: Int) -> Int32? {
        guard (1...8).contains(orientation), (0...3).contains(clockwiseQuarterTurns) else { return nil }
        var result = orientation
        for _ in 0..<clockwiseQuarterTurns {
            guard let next = clockwiseOrientation(result) else { return nil }
            result = next
        }
        return result
    }

    /// Container and pixels consume the very same presentation progress.
    static func interpolatedCardSize(from: CGSize, to: CGSize, progress: Double) -> CGSize {
        guard progress.isFinite else { return from }
        let p = min(1, max(0, progress))
        return CGSize(width: from.width + (to.width - from.width) * p,
                      height: from.height + (to.height - from.height) * p)
    }

    struct RotatingCardLayout {
        let imageSize: CGSize
        let cardSize: CGSize
        let trailingBorder: CGFloat
        let bottomBorder: CGFloat
    }

    /// Solve the fit for the entire framed card before applying one rotation.
    /// The bottom border moves to the trailing edge in local coordinates,
    /// so it lands back at the bottom when the whole card reaches 90 degrees.
    static func rotatingCardLayout(viewport: CGSize, imageAspect: CGFloat, sideBorder: CGFloat,
                                   bottomBorder: CGFloat, progress: Double) -> RotatingCardLayout {
        guard viewport.width > 0, viewport.height > 0,
              viewport.width.isFinite, viewport.height.isFinite,
              sideBorder.isFinite, bottomBorder.isFinite else {
            return RotatingCardLayout(imageSize: .zero, cardSize: .zero, trailingBorder: 0, bottomBorder: 0)
        }
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        let angle = p * .pi / 2
        let c = CGFloat(cos(angle))
        let s = CGFloat(sin(angle))
        let aspect = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 1
        let side = max(0, sideBorder)
        let extra = max(0, bottomBorder - side)
        let trailing = side + extra * p
        let bottom = side + extra * (1 - p)
        let horizontal = side + trailing
        let vertical = side + bottom
        let height = max(0, min(
            (viewport.width - c * horizontal - s * vertical) / (c * aspect + s),
            (viewport.height - s * horizontal - c * vertical) / (s * aspect + c)
        ))
        let image = CGSize(width: height * aspect, height: height)
        return RotatingCardLayout(imageSize: image,
                                  cardSize: CGSize(width: image.width + horizontal, height: image.height + vertical),
                                  trailingBorder: trailing, bottomBorder: bottom)
    }

    struct RotationBadgeLayout {
        let center: CGPoint
        let scale: CGFloat
    }

    static func rotationBadgeLayout(in image: CGRect, badgeSide: CGFloat = 22, inset: CGFloat = 8) -> RotationBadgeLayout {
        guard image.width > 0, image.height > 0, badgeSide > 0 else {
            return RotationBadgeLayout(center: CGPoint(x: image.midX, y: image.midY), scale: 0)
        }
        let scale = min(1, min(image.width, image.height) / badgeSide)
        let half = badgeSide * scale / 2
        return RotationBadgeLayout(
            center: CGPoint(x: image.maxX - min(inset + half, image.width / 2),
                            y: image.maxY - min(inset + half, image.height / 2)),
            scale: scale)
    }

    static func isRestingAtDefaultScale(zoomScale: CGFloat, minimumZoomScale: CGFloat,
                                       isZooming: Bool, isZoomBouncing: Bool,
                                       isTransitioning: Bool) -> Bool {
        zoomScale.isFinite && minimumZoomScale.isFinite && minimumZoomScale > 0
            && abs(zoomScale - minimumZoomScale) < 0.001
            && !isZooming && !isZoomBouncing && !isTransitioning
    }

}
