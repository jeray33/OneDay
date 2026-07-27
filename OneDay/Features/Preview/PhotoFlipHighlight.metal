#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 photoFlipHighlight(
    float2 position,
    SwiftUI::Layer layer,
    float progress,
    float phase,
    float width,
    float height
) {
    half4 base = layer.sample(position);

    float safeWidth = max(width, 1.0);
    float safeHeight = max(height, 1.0);
    float2 uv = float2(position.x / safeWidth, position.y / safeHeight);

    float sweepCenter = mix(-0.25, 1.25, clamp(phase, 0.0, 1.0));
    float bandWidth = mix(0.09, 0.18, clamp(progress, 0.0, 1.0));
    float dx = abs(uv.x - sweepCenter);
    float band = exp(-(dx * dx) / max(bandWidth * bandWidth, 0.0001));

    float topFade = smoothstep(0.0, 0.12, uv.y);
    float bottomFade = 1.0 - smoothstep(0.88, 1.0, uv.y);
    float verticalMask = topFade * bottomFade;

    float pulse = 0.55 + 0.45 * sin((uv.y + phase) * 9.0);
    float intensity = clamp(progress, 0.0, 1.0) * band * verticalMask * pulse * 0.32;

    half3 highlight = half3(intensity, intensity, intensity * 0.92);
    base.rgb = min(base.rgb + highlight, half3(1.0));
    return base;
}
