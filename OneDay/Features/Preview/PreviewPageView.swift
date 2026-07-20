import SwiftUI
import AVKit
import Photos

struct PreviewPageView: View {
    let item: PhotoItem
    let model: DayViewModel
    var onZoomChanged: (Bool) -> Void = { _ in }

    @State private var image: UIImage?
    @State private var player: AVPlayer?

    // Border config mirrors the photo page / cover (width + style).
    private var borderScale: CGFloat { model.borderWidth.scale }
    private var isPolaroid: Bool { model.borderStyle.isPolaroid }
    private var sideBorder: CGFloat {
        let base = (12 * borderScale).rounded()
        return isPolaroid ? max(base, 10) : base
    }
    private var topBorder: CGFloat { sideBorder }
    /// Bottom edge thickness: tall for Polaroid, symmetric otherwise.
    private var bottomBorder: CGFloat { isPolaroid ? sideBorder + 46 : sideBorder }
    private var cardColor: Color { model.frameColor(for: item) }

    var body: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            ZStack {
                if item.isVideo {
                    if let player {
                        VStack(spacing: 0) {
                            VideoPlayer(player: player)
                                .frame(width: card.width - sideBorder * 2,
                                       height: card.height - topBorder - bottomBorder)
                                .padding(.horizontal, sideBorder)
                                .padding(.top, topBorder)
                                .padding(.bottom, bottomBorder)
                        }
                        .frame(width: card.width, height: card.height)
                        .background(cardColor)
                    } else {
                        ProgressView().tint(.white)
                    }
                } else if let image {
                    ZoomableImageView(
                        image: image,
                        displaySize: card,
                        sideBorder: sideBorder,
                        topBorder: topBorder,
                        captionHeight: bottomBorder,
                        cardColor: cardColor,
                        onZoomChanged: onZoomChanged
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.id) {
                await load(targetSize: geo.size)
            }
            .onDisappear { player?.pause() }
        }
        .ignoresSafeArea()
    }

    private func cardSize(in size: CGSize) -> CGSize {
        let sideMargin: CGFloat = 20
        let verticalMargin: CGFloat = 20
        let maxImageWidth = max(1, size.width - sideMargin * 2 - sideBorder * 2)
        let maxImageHeight = max(1, size.height - verticalMargin * 2 - topBorder - bottomBorder)
        let aspect = max(item.aspectRatio, 0.1)
        var width = maxImageWidth
        var height = width / aspect
        if height > maxImageHeight {
            height = maxImageHeight
            width = height * aspect
        }
        return CGSize(width: width + sideBorder * 2,
                      height: height + topBorder + bottomBorder)
    }

    private func load(targetSize: CGSize) async {
        if item.isVideo {
            if let playerItem = await ImageLoader.shared.playerItem(for: item.asset) {
                player = AVPlayer(playerItem: playerItem)
                player?.play()
            }
        } else {
            let scale = UIScreen.main.scale
            let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
            for await frame in ImageLoader.shared.stream(
                asset: item.asset,
                targetSize: pixelSize,
                contentMode: .aspectFit,
                highQuality: true
            ) {
                image = frame
            }
        }
    }
}
