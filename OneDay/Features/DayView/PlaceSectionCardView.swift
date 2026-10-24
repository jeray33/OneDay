import SwiftUI

struct PlaceSectionCardView: View {
    let card: PlaceSectionCard
    let width: CGFloat
    let ratio: PlaceCardRatio
    let font: CoverDateFont
    let titleSize: CGFloat
    let cornerRadius: CGFloat
    let shadowLevel: PhotoShadowLevel

    var body: some View {
        let sizing = PlaceSectionCard.Sizing(width: width, ratio: ratio)
        let color = card.color
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
        .background(Color(red: color.red, green: color.green, blue: color.blue))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.16 * Double(shadowLevel.scale)),
                radius: 7 * shadowLevel.scale, x: 0, y: 4 * shadowLevel.scale)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
