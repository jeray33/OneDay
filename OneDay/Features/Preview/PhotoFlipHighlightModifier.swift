import SwiftUI

struct PhotoFlipHighlightModifier: ViewModifier {
    let flipAngle: Double
    let cardSize: CGSize

    func body(content: Content) -> some View {
        let normalized = min(max(flipAngle / 180, 0), 1)
        let progress = abs(sin(flipAngle * .pi / 180))
        let shader = Shader(
            function: .init(library: .default, name: "photoFlipHighlight"),
            arguments: [
                .float(Float(progress)),
                .float(Float(normalized)),
                .float(Float(max(cardSize.width, 1))),
                .float(Float(max(cardSize.height, 1)))
            ]
        )

        content.layerEffect(
            shader,
            maxSampleOffset: .zero,
            isEnabled: progress > 0.001
        )
    }
}

extension View {
    func photoFlipHighlight(flipAngle: Double, cardSize: CGSize) -> some View {
        modifier(PhotoFlipHighlightModifier(flipAngle: flipAngle, cardSize: cardSize))
    }
}
