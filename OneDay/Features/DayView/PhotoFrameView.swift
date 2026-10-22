import SwiftUI

/// A photo or video thumbnail with the signature white magazine border.
/// `width` is the TOTAL framed width (image + border), so blocks never overflow.
struct PhotoFrameView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.heroSourceID) private var heroSourceID

    let item: PhotoItem
    var width: CGFloat
    var border: CGFloat = 8
    var kenBurns: Bool = false
    var favorite: Bool = false
    /// When `true`, renders a small circular badge (top-trailing) marking the
    /// photo as contributed by another participant of the user's iCloud Shared
    /// Photo Library.
    var shared: Bool = false
    var ratioOverride: CGFloat? = nil
    var ratioRange: ClosedRange<CGFloat> = 0.55...1.85
    var borderColor: Color = Theme.frame
    /// Polaroid look: a tall white strip along the bottom edge.
    var polaroid: Bool = false
    var minimumPolaroidBottom: CGFloat = 20
    var shadowLevel: PhotoShadowLevel = .max
    var showCaption: Bool = false
    var cornerRadius: CGFloat = 0
    var onEditCaption: ((PhotoItem) -> Void)? = nil

    private let captionFontSize: CGFloat = 12

    private var ratio: CGFloat {
        min(max(ratioOverride ?? item.aspectRatio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    private var imageSize: CGSize {
        let w = max(width - border * 2, 1)
        return CGSize(width: w, height: (w / ratio).rounded())
    }

    /// Bottom edge thickness. Polaroid keeps thin top/sides but a chunky bottom.
    private var bottomBorder: CGFloat {
        polaroid ? border + max(imageSize.height * 0.16, minimumPolaroidBottom) : border
    }

    var body: some View {
        VStack(spacing: 6) {
            framedImage
            if showCaption, let caption = item.caption, !caption.isEmpty {
                HStack(spacing: 4) {
                    Text(caption)
                        .font(Theme.serif(captionFontSize, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if let onEditCaption, item.sharedCapabilities.canEditCaption {
                        Button {
                            onEditCaption(item)
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.ink.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: width)
    }

    private var framedImage: some View {
        PHImageView(asset: item.asset, displaySize: imageSize, fill: true, kenBurns: kenBurns)
            .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - border, 0), style: .continuous))
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .overlay(alignment: .topLeading) { favoriteBadge }
            .overlay(alignment: .topTrailing) { sharedBadge }
            .padding(.top, border)
            .padding(.horizontal, border)
            .padding(.bottom, bottomBorder)
            .background(borderColor)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                if heroSourceID == item.id {
                    GeometryReader { geo in
                        let rect = geo.frame(in: .named(heroCoordinateSpace))
                        let scaleX = geo.size.width > 0 ? rect.width / geo.size.width : 1
                        let scaleY = geo.size.height > 0 ? rect.height / geo.size.height : 1
                        Color.clear.preference(
                            key: HeroCellFrameKey.self,
                            value: [item.id: HeroCellInfo(
                                rect: rect,
                                border: border * scaleX,
                                bottomBorder: bottomBorder * scaleY,
                                cornerRadius: cornerRadius * scaleX,
                                contentVersion: item.contentVersion
                            )]
                        )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.15), lineWidth: 1 / max(displayScale, 1))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.16 * Double(shadowLevel.scale)),
                    radius: 7 * shadowLevel.scale,
                    x: 0,
                    y: 4 * shadowLevel.scale)
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if favorite {
            Image(systemName: "heart.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.red)
                .padding(3)
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(4)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var sharedBadge: some View {
        if shared {
            Image(systemName: "person.2.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Theme.ink)
                .padding(3)
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(4)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var videoBadge: some View {
        if item.isVideo {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                if let text = item.durationText {
                    Text(text)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
        }
    }
}
