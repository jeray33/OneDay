import SwiftUI

struct PlaceSectionCardView: View {
    let card: PlaceSectionCard
    let width: CGFloat
    let ratio: PlaceCardRatio
    let font: CoverDateFont
    let titleSize: CGFloat
    let cornerRadius: CGFloat
    let shadowLevel: PhotoShadowLevel
    var style: PlaceCardStyle = .solid

    var body: some View {
        let sizing = PlaceSectionCard.Sizing(width: width, ratio: ratio)
        VStack(alignment: .leading, spacing: sizing.spacing) {
            Group {
                if card.isLoading {
                    PlaceLoadingDots()
                } else {
                    PlaceNameText(
                        text: card.title,
                        secondaryFont: font.font(max(9, sizing.titleFontSize(preferred: titleSize) * 0.68)),
                        primaryLineLimit: PlaceNaming.TitleLines(card.title).chinese == nil
                            ? sizing.titleLineLimit : max(1, sizing.titleLineLimit - 1))
                }
            }
                .font(font.font(sizing.titleFontSize(preferred: titleSize)))
                .lineLimit(sizing.titleLineLimit)
                .minimumScaleFactor(0.7)
            if !card.timeText.isEmpty {
                Text(sizing.wrapsTime
                     ? card.timeText.replacingOccurrences(of: " – ", with: "\n")
                     : card.timeText)
                    .font(.system(size: sizing.timeFontSize, weight: .regular, design: .monospaced))
                    .lineLimit(sizing.wrapsTime ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(white: 0.15))
        .padding(sizing.inset)
        .frame(width: sizing.width, height: sizing.height, alignment: .topLeading)
        .background { cardBackground }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.16 * Double(shadowLevel.scale)),
                radius: 7 * shadowLevel.scale, x: 0, y: 4 * shadowLevel.scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch style {
        case .solid:
            color(card.color)
        case .diffuse:
            diffuseBackground
        case .glowEdge:
            glowEdgeBackground
        }
    }

    private var diffuseBackground: some View {
        let gradient = card.diffuseGradient
        return GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                color(gradient.base)
                ZStack {
                    ForEach(gradient.blobs.indices, id: \.self) { index in
                        let blob = gradient.blobs[index]
                        Ellipse()
                            .fill(color(blob.color))
                            .frame(width: blob.width * size.width, height: blob.height * size.height)
                            .rotationEffect(.degrees(blob.rotation))
                            .position(x: blob.x * size.width, y: blob.y * size.height)
                            .opacity(blob.opacity)
                    }
                }
                .blur(radius: min(size.width, size.height) * 0.22)
            }
        }
        .drawingGroup()
    }

    private var glowEdgeBackground: some View {
        let glow = card.edgeGlow
        return GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let band = side * 0.14
            let softness = side * 0.09
            // The band extends past the card so only its inner falloff shows,
            // and its corners stay concentric with the card's own corners.
            ZStack {
                LinearGradient(colors: [color(glow.centerTop), color(glow.centerBottom)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: cornerRadius + softness, style: .continuous)
                    .strokeBorder(color(glow.edge), lineWidth: band + softness)
                    .padding(-softness)
                    .blur(radius: softness)
            }
        }
        .drawingGroup()
    }
    private func color(_ pastel: PlaceSectionCard.Pastel) -> Color {
        Color(red: pastel.red, green: pastel.green, blue: pastel.blue)
    }
}
