import Foundation

/// Preserve the day card's relative curvature as its framed width changes.
struct PhotoCornerGeometry: Equatable {
    let referenceWidth: CGFloat
    let cornerRadius: CGFloat

    func radius(for size: CGSize) -> CGFloat {
        guard referenceWidth.isFinite, referenceWidth > 0,
              cornerRadius.isFinite, cornerRadius > 0,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return 0 }
        return min(cornerRadius * size.width / referenceWidth,
                   min(size.width, size.height) / 2)
    }
}
