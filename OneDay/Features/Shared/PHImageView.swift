import SwiftUI
import Photos

struct PHImageView: View {
    let asset: PHAsset
    var displaySize: CGSize
    var fill: Bool = true
    var highQuality: Bool = false
    var kenBurns: Bool = false

    @State private var image: UIImage?
    @State private var animateKenBurns = false

    private var targetSize: CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: max(displaySize.width, 1) * scale,
                      height: max(displaySize.height, 1) * scale)
    }

    private var kenBurnsScale: CGFloat {
        guard kenBurns else { return 1 }
        return animateKenBurns ? 1.12 : 1.0
    }

    var body: some View {
        ZStack {
            Color(white: 0.92)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .scaleEffect(kenBurnsScale)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
        .onAppear {
            guard kenBurns else { return }
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                animateKenBurns = true
            }
        }
        .task(id: asset.localIdentifier) {
            for await frame in ImageLoader.shared.stream(
                asset: asset,
                targetSize: targetSize,
                contentMode: fill ? .aspectFill : .aspectFit,
                highQuality: highQuality
            ) {
                image = frame
            }
        }
    }
}
