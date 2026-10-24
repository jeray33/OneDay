import SwiftUI

/// A photo or video thumbnail with the signature white magazine border.
/// `width` is the TOTAL framed width (image + border), so blocks never overflow.
struct PhotoFrameView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.heroSourceID) private var heroSourceID

    let item: PhotoItem
    var width: CGFloat
    var border: CGFloat = 8
    var favorite: Bool = false
    /// When `true`, renders a small circular badge (top-trailing) marking the
    /// photo as contributed by another participant of the user's iCloud Shared
    /// Photo Library.
    var shared: Bool = false
    var ratioRange: ClosedRange<CGFloat> = 0.55...1.85
    var shadowLevel: PhotoShadowLevel = .max
    var showCaption: Bool = false
    var cornerRadius: CGFloat = 0
    /// Keep the full cell geometry when an off-screen waterfall image unloads.
    var loadsImage: Bool = true
    /// Cached text measurement makes virtual layout independent of cell views.
    var measuredCaptionHeight: CGFloat? = nil

    private let captionFontSize: CGFloat = 12

    private var ratio: CGFloat {
        min(max(item.aspectRatio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    private var imageSize: CGSize {
        let w = max(width - border * 2, 1)
        return CGSize(width: w, height: (w / ratio).rounded())
    }

    var body: some View {
        VStack(spacing: 6) {
            framedImage
            if showCaption, let caption = item.caption, !caption.isEmpty {
                Text(caption)
                    .font(Theme.serif(captionFontSize, weight: .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .frame(height: measuredCaptionHeight)
            }
        }
        .frame(width: width)
    }

    private var framedImage: some View {
        Group {
            if loadsImage {
                PHImageView(asset: item.asset, displaySize: imageSize, fill: true)
            } else {
                Color(white: 0.92)
                    .frame(width: imageSize.width, height: imageSize.height)
            }
        }
            .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - border, 0), style: .continuous))
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .overlay(alignment: .topLeading) { favoriteBadge }
            .overlay(alignment: .topTrailing) { sharedBadge }
            .padding(.top, border)
            .padding(.horizontal, border)
            .padding(.bottom, border)
            .background(Theme.frame)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                if heroSourceID == item.id {
                    GeometryReader { geo in
                        // Content space: the rect is stable while the page
                        // scrolls, so this report only changes when the
                        // layout itself changes.
                        let rect = geo.frame(in: .named(dayContentSpace))
                        let scaleX = geo.size.width > 0 ? rect.width / geo.size.width : 1
                        let scaleY = geo.size.height > 0 ? rect.height / geo.size.height : 1
                        Color.clear.preference(
                            key: HeroCellFrameKey.self,
                            value: [item.id: HeroCellInfo(
                                rect: rect,
                                border: border * scaleX,
                                bottomBorder: border * scaleY,
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
            // The shadow hangs from the card silhouette alone rather than the
            // photo and badge composite, so it is never re-rasterized when the
            // image or badges update.
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.frame)
                    .shadow(color: .black.opacity(0.16 * Double(shadowLevel.scale)),
                            radius: 7 * shadowLevel.scale,
                            x: 0,
                            y: 4 * shadowLevel.scale)
            )
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if favorite {
            Image(systemName: "heart.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.red)
                .padding(3)
                .glassEffect(.regular,
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
                .glassEffect(.regular,
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
