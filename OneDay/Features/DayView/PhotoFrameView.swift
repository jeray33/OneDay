import SwiftUI

/// A photo or video thumbnail with the signature white magazine border.
/// `width` is the TOTAL framed width (image + border), so blocks never overflow.
struct PhotoFrameView: View {
    let item: PhotoItem
    var width: CGFloat
    var border: CGFloat = 8
    var kenBurns: Bool = false
    var favorite: Bool = false
    var ratioOverride: CGFloat? = nil
    var borderColor: Color = Theme.frame

    private var ratio: CGFloat {
        min(max(ratioOverride ?? item.aspectRatio, 0.55), 1.85)
    }

    private var imageSize: CGSize {
        let w = max(width - border * 2, 1)
        return CGSize(width: w, height: (w / ratio).rounded())
    }

    var body: some View {
        PHImageView(asset: item.asset, displaySize: imageSize, fill: true, kenBurns: kenBurns)
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .overlay(alignment: .topLeading) { favoriteBadge }
            .padding(border)
            .background(borderColor)
            .shadow(color: .black.opacity(0.16), radius: 7, x: 0, y: 4)
    }

    @ViewBuilder
    private var favoriteBadge: some View {
        if favorite {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Theme.accent, in: Circle())
                .padding(8)
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
