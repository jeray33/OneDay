import Foundation
import CoreGraphics

/// Media-independent geometry used by the hero renderer, including cropped
/// screenshots, panoramas and video/Live Photo poster frames.
enum PhotoFrameGeometry {
    static func imageSize(card: CGSize, border: CGFloat, bottomBorder: CGFloat) -> CGSize {
        CGSize(width: max(0, card.width - border * 2),
               height: max(0, card.height - border - bottomBorder))
    }

    /// Fill the entire clipped viewport. Aspect-fit would leave the image's
    /// rectangular corners inside that viewport, outside its rounded corners.
    static func fillSize(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width.isFinite, image.height.isFinite,
              image.width > 0, image.height > 0,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = max(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    static func validAspectRatio(_ aspect: CGFloat) -> CGFloat {
        aspect.isFinite && aspect > 0 ? aspect : 1
    }
}
