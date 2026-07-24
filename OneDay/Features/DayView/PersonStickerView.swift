import SwiftUI

/// Displays a single person cut-out sticker. The white outline is already
/// baked into the sticker image by `PersonStickerExtractor`.
struct PersonStickerView: View {
    let sticker: PersonSticker
    var maxHeight: CGFloat = 220
    var shadowLevel: PhotoShadowLevel = .max

    var body: some View {
        Image(uiImage: sticker.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maxHeight)
            .shadow(color: .black.opacity(0.22 * Double(shadowLevel.scale)),
                    radius: 6 * shadowLevel.scale,
                    x: 0,
                    y: 4 * shadowLevel.scale)
            .accessibilityHidden(true)
    }
}
