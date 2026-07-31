import SwiftUI

extension View {
    func progressiveBlur(
        radius: CGFloat,
        maxSampleCount: Int = 25,
        verticalPassFirst: Bool = false,
        mask: Image
    ) -> some View {
        visualEffect { content, _ in
            content.progressiveBlur(
                radius: radius,
                maxSampleCount: maxSampleCount,
                verticalPassFirst: verticalPassFirst,
                mask: mask
            )
        }
    }

    func progressiveBlur(
        radius: CGFloat,
        maxSampleCount: Int = 25,
        verticalPassFirst: Bool = false,
        maskRenderer: @escaping (GeometryProxy, inout GraphicsContext) -> Void
    ) -> some View {
        visualEffect { content, geometryProxy in
            content.progressiveBlur(
                radius: radius,
                maxSampleCount: maxSampleCount,
                verticalPassFirst: verticalPassFirst,
                mask: Image(size: geometryProxy.size) { context in
                    maskRenderer(geometryProxy, &context)
                }
            )
        }
    }
}

extension VisualEffect {
    func progressiveBlur(
        radius: CGFloat,
        maxSampleCount: Int = 25,
        verticalPassFirst: Bool = false,
        mask: Image,
        isEnabled: Bool = true
    ) -> some VisualEffect {
        layerEffect(
            ShaderLibrary.progressiveBlur(
                .boundingRect,
                .float(radius),
                .float(CGFloat(maxSampleCount)),
                .image(mask),
                .float(verticalPassFirst ? 1 : 0)
            ),
            maxSampleOffset: CGSize(width: radius, height: radius),
            isEnabled: isEnabled
        )
        .layerEffect(
            ShaderLibrary.progressiveBlur(
                .boundingRect,
                .float(radius),
                .float(CGFloat(maxSampleCount)),
                .image(mask),
                .float(verticalPassFirst ? 0 : 1)
            ),
            maxSampleOffset: CGSize(width: radius, height: radius),
            isEnabled: isEnabled
        )
    }
}
