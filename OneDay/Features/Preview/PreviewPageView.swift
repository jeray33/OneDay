import SwiftUI
import AVKit
import Photos

struct PreviewPageView: View {
    let item: PhotoItem
    var onZoomChanged: (Bool) -> Void = { _ in }

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var place: String?

    private let sideBorder: CGFloat = 8
    private let topBorder: CGFloat = 8
    private let captionHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            ZStack {
                if item.isVideo {
                    if let player {
                        VStack(spacing: 0) {
                            VideoPlayer(player: player)
                                .frame(width: card.width - sideBorder * 2,
                                       height: card.height - topBorder - captionHeight)
                                .padding(.horizontal, sideBorder)
                                .padding(.top, topBorder)
                            caption
                                .frame(width: card.width - sideBorder * 2, height: captionHeight)
                        }
                        .frame(width: card.width, height: card.height)
                        .background(.white)
                    } else {
                        ProgressView().tint(.white)
                    }
                } else if let image {
                    ZoomableImageView(
                        image: image,
                        displaySize: card,
                        sideBorder: sideBorder,
                        topBorder: topBorder,
                        captionHeight: captionHeight,
                        captionLine1: captionLine1,
                        captionLine2: captionLine2,
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
                await resolvePlace()
            }
            .onDisappear { player?.pause() }
        }
        .ignoresSafeArea()
    }

    private var caption: some View {
        VStack(spacing: 2) {
            if let line1 = captionLine1, !line1.isEmpty {
                Text(line1)
                    .font(Theme.serif(13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.18))
            }
            if let line2 = captionLine2, !line2.isEmpty {
                Text(line2)
                    .font(Theme.serif(11))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
    }

    private var captionLine1: String? { place }

    private var captionLine2: String? {
        let date = item.creationDate ?? Date()
        let c = DateText.components(date)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(c.year).\(c.month).\(c.day) \(DateText.weekday(date)) \(f.string(from: date))"
    }

    private func cardSize(in size: CGSize) -> CGSize {
        let sideMargin: CGFloat = 20
        let verticalMargin: CGFloat = 20
        let maxImageWidth = max(1, size.width - sideMargin * 2 - sideBorder * 2)
        let maxImageHeight = max(1, size.height - verticalMargin * 2 - topBorder - captionHeight)
        let aspect = max(item.aspectRatio, 0.1)
        var width = maxImageWidth
        var height = width / aspect
        if height > maxImageHeight {
            height = maxImageHeight
            width = height * aspect
        }
        return CGSize(width: width + sideBorder * 2,
                      height: height + topBorder + captionHeight)
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

    private func resolvePlace() async {
        guard let location = item.location else { return }
        place = await LocationResolver.shared.name(for: location)
    }
}
