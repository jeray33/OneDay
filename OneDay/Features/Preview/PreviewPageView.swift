import SwiftUI
import AVKit
import Photos
struct SwipePreviewEffectConfig {
    var yawEnabled: Bool = false
    var yawMaxDegrees: Double = 12
    var glossEnabled: Bool = false
    var glossStrength: Double = 0.35
    var speedBiasEnabled: Bool = false
    var incomingOffsetFactor: Double = 0.18
    var outgoingOffsetFactor: Double = 0.08
}

struct PreviewPageView: View {
    let item: PhotoItem
    let model: DayViewModel
    var onZoomChanged: (Bool) -> Void = { _ in }
    var onEditCaption: ((PhotoItem) -> Void)? = nil
    var photoOffsetX: CGFloat = 0
    var photoOffsetY: CGFloat = 0
    var photoScale: CGFloat = 1
    var infoOpacity: Double = 1
    var isZoomed: Bool = false
    var flipAngle: Double = 0
    var swipeEffectConfig: SwipePreviewEffectConfig = .init()
    var onFlipRequest: () -> Void = {}
    var onFlipBackRequest: () -> Void = {}

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var place: String?
    @State private var metadataSnapshot: PhotoMetadataSnapshot?
    @State private var isMetadataLoading = false

    private var sideBorder: CGFloat {
        let base = (12 * model.borderWidth.scale).rounded()
        return model.borderStyle.isPolaroid ? max(base, 10) : base
    }
    private var topBorder: CGFloat { sideBorder }
    private var baseBottomBorder: CGFloat { model.borderStyle.isPolaroid ? sideBorder + 46 : sideBorder }
    private var cardColor: Color { model.frameColor(for: item) }
    private var captionColor: Color {
        model.pageColorScheme == .dark ? .white : Color(white: 0.15)
    }
    private var isBackVisible: Bool {
        flipAngle > 90
    }

    private var dateLine: String? {
        let date = item.creationDate ?? Date()
        let c = DateText.components(date)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(c.year).\(c.month).\(c.day) \(DateText.weekday(date)) \(f.string(from: date))"
    }

    private var infoCaption: String? {
        let text = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var body: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let infoReservedHeight: CGFloat = 108
            let pageWidth = max(1, geo.size.width)
            let rawProgress = geo.frame(in: .global).minX / pageWidth
            let swipeProgress = adjustedSwipeProgress(from: rawProgress)
            let swipeOffsetX = swipeHorizontalOffsetX(progress: rawProgress, pageWidth: pageWidth)
            let outgoingOpacity = outgoingPageOpacity(progress: rawProgress)
            VStack(spacing: 20) {
                Spacer(minLength: 6)
                flippableCard(card: card, swipeProgress: swipeProgress)
                    .scaleEffect(photoScale, anchor: .center)
                    .offset(x: photoOffsetX + swipeOffsetX)
                    .offset(y: photoOffsetY)
                    .opacity(outgoingOpacity)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(card.height + 10, geo.size.height - infoReservedHeight))
                infoBlock
                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.id) {
                await load(targetSize: geo.size)
                await updatePlace()
            }
            .onChange(of: item.id) {
                metadataSnapshot = nil
            }
            .onChange(of: isBackVisible) {
                if isBackVisible {
                    Task { await loadMetadataIfNeeded() }
                }
            }
            .onDisappear { player?.pause() }
            .zIndex(incomingPageZIndex(for: rawProgress))
        }
        .ignoresSafeArea()
    }

    private func flippableCard(card: CGSize, swipeProgress: Double) -> some View {
        ZStack {
            mediaCard(card: card)
                .rotation3DEffect(
                    .degrees(flipAngle),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )
                .opacity(flipAngle <= 90 ? 1 : 0)
                .allowsHitTesting(!isBackVisible)

            PhotoMetadataBackView(snapshot: metadataSnapshot, isLoading: isMetadataLoading)
                .frame(width: card.width, height: card.height)
                .rotation3DEffect(
                    .degrees(flipAngle - 180),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )
                .opacity(flipAngle > 90 ? 1 : 0)
                .allowsHitTesting(isBackVisible)
                .onTapGesture {
                    onFlipBackRequest()
                }
        }
        .frame(width: card.width, height: card.height)
        .overlay {
            flipHighlightOverlay
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay {
            swipeGlossOverlay(progress: swipeProgress)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .rotation3DEffect(
            .degrees(swipeYawAngle(progress: swipeProgress)),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.85
        )
        .animation(.easeInOut(duration: 0.6), value: flipAngle)
    }

    private var flipHighlightOverlay: some View {
        let progress = abs(sin(flipAngle * .pi / 180))
        let normalized = min(max(flipAngle / 180, 0), 1)
        let center = min(max(-0.25 + normalized * 1.5, 0), 1)
        let lead = max(0, center - 0.16)
        let trail = min(1, center + 0.16)
        let shadowLead = max(0, center - 0.08)
        let shadowTrail = min(1, center + 0.26)
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: lead),
                    .init(color: .white.opacity(0.42 * progress), location: center),
                    .init(color: .white.opacity(0), location: trail)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.screen)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: shadowLead),
                    .init(color: .black.opacity(0.16 * progress), location: min(1, center + 0.12)),
                    .init(color: .black.opacity(0), location: shadowTrail)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.multiply)
        }
        .allowsHitTesting(false)
    }

    private func swipeYawAngle(progress: Double) -> Double {
        guard swipeEffectConfig.yawEnabled, flipAngle < 1, !isZoomed else { return 0 }
        return -progress * swipeEffectConfig.yawMaxDegrees
    }

    private func adjustedSwipeProgress(from raw: Double) -> Double {
        let clamped = max(-1.2, min(1.2, raw))
        guard swipeEffectConfig.speedBiasEnabled else { return clamped }
        if clamped > 0 {
            return min(1.2, clamped * 1.2)
        } else if clamped < 0 {
            return max(-1.2, clamped * 0.92)
        } else {
            return 0
        }
    }

    private func incomingPageZIndex(for rawProgress: Double) -> Double {
        // During left swipe: current page goes 0 -> -1, next page goes 1 -> 0.
        // Keep incoming (positive progress) above current for the desired overlap.
        rawProgress > 0 ? 2 : 1
    }

    private func outgoingPageOpacity(progress: Double) -> Double {
        // Only fade the outgoing current page near the end of left-swipe
        // so handoff to next page feels smooth instead of a last-frame pop.
        guard progress < 0 else { return 1 }
        let p = min(1, max(0, abs(progress)))
        let start: Double = 0.78
        guard p > start else { return 1 }
        let t = min(1, max(0, (p - start) / (1 - start)))
        let eased = t * t * (3 - 2 * t)
        return 1 - eased * 0.5
    }

    private func swipeHorizontalOffsetX(progress: Double, pageWidth: Double) -> CGFloat {
        guard swipeEffectConfig.speedBiasEnabled, flipAngle < 1, !isZoomed else { return 0 }
        // progress semantics:
        // current page during left-swipe: 0 -> -1
        // incoming next page during left-swipe: 1 -> 0
        if progress < 0 {
            let t = min(1, max(0, abs(progress))) // 0 -> 1 as swipe advances
            let curve = pow(t, 1.08)
            return CGFloat(curve * pageWidth * swipeEffectConfig.outgoingOffsetFactor)
        } else if progress > 0 {
            let enter = min(1, max(0, 1 - progress)) // 0 -> 1 as next page approaches center
            let endFade = min(1, max(0, progress / 0.42)) // starts fading out earlier to avoid elastic ending
            let curve = pow(enter, 1.05) * pow(endFade, 1.2)
            return CGFloat(-curve * pageWidth * swipeEffectConfig.incomingOffsetFactor)
        } else {
            return 0
        }
    }

    @ViewBuilder
    private func swipeGlossOverlay(progress: Double) -> some View {
        if swipeEffectConfig.glossEnabled, flipAngle < 1, !isZoomed {
            let strength = max(0, min(1, swipeEffectConfig.glossStrength))
            let p = max(-1, min(1, progress))
            let center = 0.5 - p * 0.42
            let lead = max(0, center - 0.14)
            let trail = min(1, center + 0.14)
            let shadowLead = max(0, center - 0.06)
            let shadowTrail = min(1, center + 0.22)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: lead),
                        .init(color: .white.opacity(0.36 * strength), location: center),
                        .init(color: .white.opacity(0), location: trail)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.screen)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: shadowLead),
                        .init(color: .black.opacity(0.12 * strength), location: min(1, center + 0.1)),
                        .init(color: .black.opacity(0), location: shadowTrail)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.multiply)
            }
            .allowsHitTesting(false)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func mediaCard(card: CGSize) -> some View {
        if item.isVideo {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: card.width - sideBorder * 2,
                           height: card.height - topBorder - baseBottomBorder)
                    .padding(.horizontal, sideBorder)
                    .padding(.top, topBorder)
                    .padding(.bottom, baseBottomBorder)
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
                captionHeight: baseBottomBorder,
                cardColor: cardColor,
                onZoomChanged: onZoomChanged,
                caption: nil,
                captionColor: captionColor,
                onEditCaption: nil
            )
        } else {
            ProgressView().tint(.white)
        }
    }

    private var infoBlock: some View {
        VStack(spacing: 2) {
            if let place, !place.isEmpty {
                Text(place)
                    .font(Theme.serif(14, weight: .semibold))
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
            }
            if let dateLine, !dateLine.isEmpty {
                Text(dateLine)
                    .font(Theme.serif(11))
                    .foregroundStyle(captionColor.opacity(0.82))
                    .lineLimit(1)
            }
            if let infoCaption {
                Text(infoCaption)
                    .font(Theme.serif(12))
                    .foregroundStyle(captionColor.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 24)
        .opacity(infoOpacity)
        .animation(.easeInOut(duration: 0.16), value: infoOpacity)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isBackVisible {
                onFlipRequest()
            }
        }
    }

    private func cardSize(in size: CGSize) -> CGSize {
        let sideMargin: CGFloat = 20
        let verticalMargin: CGFloat = 20
        let reservedInfoHeight: CGFloat = 64
        let maxImageWidth = max(1, size.width - sideMargin * 2 - sideBorder * 2)
        let maxImageHeight = max(1, size.height - verticalMargin * 2 - topBorder - baseBottomBorder - reservedInfoHeight)
        let aspect = max(item.aspectRatio, 0.1)
        var width = maxImageWidth
        var height = width / aspect
        if height > maxImageHeight {
            height = maxImageHeight
            width = height * aspect
        }
        return CGSize(width: width + sideBorder * 2,
                      height: height + topBorder + baseBottomBorder)
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

    private func loadMetadataIfNeeded() async {
        guard metadataSnapshot == nil, !isMetadataLoading else { return }
        isMetadataLoading = true
        let snapshot = await PhotoMetadataService.shared.metadata(for: item.asset)
        metadataSnapshot = snapshot
        isMetadataLoading = false
    }

    private func updatePlace() async {
        guard let location = item.location else {
            place = nil
            return
        }
        place = await LocationResolver.shared.name(for: location)
    }
}