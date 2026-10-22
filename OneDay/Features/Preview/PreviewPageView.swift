import SwiftUI
import AVKit
import Photos

enum PreviewTagBarTransition {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
    }
}

/// Interpolates the size passed into UIKit as well as the SwiftUI card overlays.
/// A normal frame animation alone leaves UIViewRepresentable at its final size.
private struct PreviewCardSizeTransition<Content: View>: View, Animatable {
    var size: CGSize
    var content: (CGSize) -> Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        content(size)
    }
}

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
    // Keep these reservations in sync with PhotoPreviewView's topBar and
    // bottomControls, plus AlbumTagBar's chip height.
    private static let topBarTopPadding: CGFloat = 8
    private static let topBarButtonHeight: CGFloat = 40
    private static let bottomControlsBottomPadding: CGFloat = 10
    private static let bottomActionBarHeight: CGFloat = 40
    private static let bottomControlsSpacing: CGFloat = 8
    private static let albumTagBarHeight: CGFloat = 28
    private static let controlClearance: CGFloat = 24

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    var isSelected = false
    var livePhotoVisitID: UUID? = nil
    var allowsLivePlayback = false
    var onPlaceResolved: (String, String) -> Void = { _, _ in }
    var interactionRecoveryID: UUID?
    var cornerGeometry: PhotoCornerGeometry?

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var place: String?
    @State private var placeAdminLine: String?
    @State private var placeStatus: PlaceLineStatus = .loading
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

    var body: some View {
        GeometryReader { geo in
            let card = cardSize(in: geo.size)
            let pageWidth = max(1, geo.size.width)
            let rawProgress = geo.frame(in: .global).minX / pageWidth
            let swipeProgress = adjustedSwipeProgress(from: rawProgress)
            let swipeOffsetX = swipeHorizontalOffsetX(progress: rawProgress, pageWidth: pageWidth)
            let outgoingOpacity = outgoingPageOpacity(progress: rawProgress)
            ZStack {
                // The zoomable card fills the whole page so a pinch / double-tap
                // can magnify the photo edge-to-edge. At rest (scale 1) the
                // bordered card is centered inside at its display size.
                PreviewCardSizeTransition(size: card) { animatedSize in
                    flippableCard(card: animatedSize, swipeProgress: swipeProgress, pageIsCentered: abs(rawProgress) < 0.005)
                }
                    .animation(PreviewTagBarTransition.animation(reduceMotion: reduceMotion), value: model.showAlbumTagBar)
                    .scaleEffect(photoScale, anchor: .center)
                    .offset(x: photoOffsetX + swipeOffsetX)
                    .offset(y: photoOffsetY)
                    .opacity(outgoingOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.id) {
                await load(targetSize: geo.size)
            }
            .task(id: item.id) {
                // Resolves in parallel with the image load; the place name
                // must not wait for a full-quality frame (which may sit in
                // iCloud) and the frame must not wait for the geocoder.
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

    private func flippableCard(card: CGSize, swipeProgress: Double, pageIsCentered: Bool) -> some View {
        let cornerRadius = scaledCornerRadius(for: card)
        return ZStack {
            mediaCard(card: card, pageIsCentered: pageIsCentered)
                .rotation3DEffect(
                    .degrees(flipAngle),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.55
                )
                .opacity(flipAngle <= 90 ? 1 : 0)
                .allowsHitTesting(!isBackVisible)

            PhotoMetadataBackView(snapshot: metadataSnapshot,
                                  isLoading: isMetadataLoading,
                                  place: place,
                                  adminLine: placeAdminLine,
                                  placeStatus: placeStatus)
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Report the *card* rect (not the full-screen area) for the hero
        // fly-back. Non-interactive so it never blocks zoom / tap gestures.
        .overlay {
            Color.clear
                .frame(width: card.width, height: card.height)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: HeroCardFrameKey.self,
                            value: [item.id: g.frame(in: .named(heroCoordinateSpace))])
                    }
                )
                .allowsHitTesting(false)
        }
        .overlay {
            flipHighlightOverlay
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
        .overlay {
            swipeGlossOverlay(progress: swipeProgress)
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
        }
        .overlay {
            sharedBadgeOverlay(card: card)
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
    private func mediaCard(card: CGSize, pageIsCentered: Bool) -> some View {
        let cornerRadius = scaledCornerRadius(for: card)
        if item.isVideo {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: card.width - sideBorder * 2,
                           height: card.height - topBorder - baseBottomBorder)
                    .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - sideBorder, 0), style: .continuous))
                    .padding(.horizontal, sideBorder)
                    .padding(.top, topBorder)
                    .padding(.bottom, baseBottomBorder)
                    .frame(width: card.width, height: card.height)
                    .background(cardColor)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
                cornerRadius: cornerRadius,
                onZoomChanged: onZoomChanged,
                caption: nil,
                captionColor: captionColor,
                onEditCaption: nil,
                livePhotoAsset: item.isLivePhoto ? item.asset : nil,
                isSelected: isSelected,
                livePhotoVisitID: livePhotoVisitID,
                allowsLivePlayback: allowsLivePlayback && pageIsCentered && !isZoomed && abs(flipAngle) < 0.001,
                interactionRecoveryID: interactionRecoveryID
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(.white)
        }
    }

    /// Glass capsule at the card's top-trailing corner marking shared origin —
    /// the preview counterpart of the grid badge, with text because the
    /// preview has room for it. Fades out with the info block while zoomed or
    /// flipping so it never floats over an edge-to-edge photo.
    private func sharedBadgeOverlay(card: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(width: card.width, height: card.height)
            if let text = item.sharedBadgeText {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.top, topBorder + 4)
                .padding(.trailing, sideBorder + 4)
            }
        }
        .opacity(infoOpacity)
        .animation(.easeInOut(duration: 0.16), value: infoOpacity)
        .allowsHitTesting(false)
    }

    private func cardSize(in size: CGSize) -> CGSize {
        let sideMargin: CGFloat = 20
        let maxImageWidth = max(1, size.width - sideMargin * 2 - sideBorder * 2)
        let topControlsHeight = topSafeAreaInset()
            + Self.topBarTopPadding
            + Self.topBarButtonHeight
        let tagBarHeight = model.showAlbumTagBar
            ? Self.bottomControlsSpacing + Self.albumTagBarHeight
            : 0
        let bottomControlsHeight = bottomSafeAreaInset()
            + Self.bottomControlsBottomPadding
            + Self.bottomActionBarHeight
            + tagBarHeight
        let verticalInset = max(topControlsHeight, bottomControlsHeight) + Self.controlClearance
        let maxCardHeight = max(1, size.height - verticalInset * 2)
        let maxImageHeight = max(1, maxCardHeight - topBorder - baseBottomBorder)
        let aspect = PhotoFrameGeometry.validAspectRatio(item.aspectRatio)
        var width = maxImageWidth
        var height = width / aspect
        if height > maxImageHeight {
            height = maxImageHeight
            width = height * aspect
        }
        return CGSize(width: width + sideBorder * 2,
                      height: height + topBorder + baseBottomBorder)
    }

    private func scaledCornerRadius(for card: CGSize) -> CGFloat {
        let reference = cornerGeometry ?? PhotoCornerGeometry(
            referenceWidth: card.width, cornerRadius: model.photoCornerRadius.value
        )
        return reference.radius(for: card)
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
            placeAdminLine = nil
            placeStatus = .none
            return
        }
        place = nil
        placeAdminLine = nil
        placeStatus = .loading
        let resolution = await LocationResolver.shared.place(for: location, priority: .userVisible)
        guard !Task.isCancelled else { return }
        switch resolution {
        case .resolved(let fields):
            place = PlaceNaming.photoTitle(fields)
            placeAdminLine = PlaceNaming.adminLine(fields)
            placeStatus = .resolved
            if let place {
                onPlaceResolved(item.id, place)
            }
        case .noResult:
            placeStatus = .unavailable
        case .failed:
            placeStatus = .failed
        }
    }
}