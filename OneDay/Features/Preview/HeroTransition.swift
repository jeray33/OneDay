import SwiftUI
import UIKit
import Photos
import os

private let previewPerformanceLogger = Logger(subsystem: "OneDay", category: "PreviewPerformance")

/// Shared coordinate space that both the photo grid cells and the preview card
/// measure themselves in, so the flight layer can hand off between them without
/// any jump.
let heroCoordinateSpace = "daySurface"

/// The day page's scroll-content coordinate space. Photo cells report their
/// frames in it, so the reports stay constant while the page scrolls and only
/// change when the layout itself changes; on-screen coordinates are derived
/// on demand (see `HeroFrameStore.screenRect(for:)`).
let dayContentSpace = "dayContent"

enum HeroPhase {
    case idle
    case openFlying
    case open
    case closeFlying
}

/// Live on-screen frame and border width of a photo grid cell.
struct HeroCellInfo: Equatable {
    var rect: CGRect
    var border: CGFloat
    var bottomBorder: CGFloat
    var cornerRadius: CGFloat
    var contentVersion: String

    var cornerGeometry: PhotoCornerGeometry {
        PhotoCornerGeometry(referenceWidth: rect.width, cornerRadius: cornerRadius)
    }
}

/// Live on-screen info of the photo grid cells, keyed by item id. Kept in a
/// reference type (not `@State`) so the very frequent updates during scrolling
/// mutate it in place without invalidating the SwiftUI body.
final class HeroFrameStore {
    var cells: [String: HeroCellInfo] = [:]
    /// Writable-space scroll offset of the day page (contentOffset.y plus the
    /// top content inset), updated every scroll frame. Cells report their
    /// frames in the content coordinate space; these two values convert them
    /// back to on-screen coordinates at the moments a flight needs them.
    var contentScrollOffset: CGFloat = 0
    var contentTopInset: CGFloat = 0

    /// The on-screen rect for a content-space frame.
    func screenRect(for rect: CGRect) -> CGRect {
        DayContentCoordinates.screenRect(
            for: rect, scrollOffset: contentScrollOffset, topInset: contentTopInset)
    }
}

struct HeroCellFrameKey: PreferenceKey {
    static var defaultValue: [String: HeroCellInfo] = [:]
    static func reduce(value: inout [String: HeroCellInfo], nextValue: () -> [String: HeroCellInfo]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct HeroCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension CGRect {
    /// Scales the rect around its own centre (turns a card's rest frame into its
    /// on-screen visual frame while a drag applies a `scaleEffect`).
    func scaledAboutCenter(_ scale: CGFloat) -> CGRect {
        let w = width * scale
        let h = height * scale
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    func offsetBy(_ translation: CGSize) -> CGRect {
        offsetBy(dx: translation.width, dy: translation.height)
    }
}

private struct HeroSourceIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var heroSourceID: String? {
        get { self[HeroSourceIDKey.self] }
        set { self[HeroSourceIDKey.self] = newValue }
    }
}

extension View {
    /// PhotoFrameView reports the actual image card, excluding any caption.
    /// Hide the complete cell while preserving its layout slot.
    func heroCell(id: String, hiddenID: String?, reportsGeometry: Bool = true) -> some View {
        self
            .opacity(id == hiddenID ? 0 : 1)
            .environment(\.heroSourceID, reportsGeometry ? id : nil)
    }
}

/// A single "framed photo" (white border + image as one integral view) that
/// flies between a grid cell rect and the preview card rect. Because the border
/// is padding+background on the same clipped image, they never separate.
struct HeroFlightView: View {
    let image: UIImage?
    let rect: CGRect
    let borderColor: Color
    let borderWidth: CGFloat
    let bottomBorderWidth: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let viewport = PhotoFrameGeometry.imageSize(
            card: rect.size, border: borderWidth, bottomBorder: bottomBorderWidth
        )
        Group {
            if let image {
                let fill = PhotoFrameGeometry.fillSize(image: image.size, viewport: viewport)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fill.width, height: fill.height)
                    .frame(width: viewport.width, height: viewport.height)
                    .clipShape(RoundedRectangle(
                        cornerRadius: max(cornerRadius - borderWidth, 0), style: .continuous
                    ))
                    .padding(.horizontal, borderWidth)
                    .padding(.top, borderWidth)
                    .padding(.bottom, bottomBorderWidth)
                    .background(borderColor)
            } else {
                borderColor
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}

/// Hosts the photo preview and the self-drawn flight layer. This view owns ALL
/// the per-frame hero state (flight rect, opacities, card frames, progress), so
/// dragging/flying the preview only re-evaluates THIS small view and never the
/// large photo-grid body it is layered over. The grid therefore stays perfectly
/// static while the preview opens and closes.
struct HeroOverlayView: View {
    let model: DayViewModel
    let frameStore: HeroFrameStore
    let namespace: Namespace.ID
    let screen: CGSize
    /// One-shot open request set by a grid-cell tap. Cleared as soon as it is
    /// consumed. Changing it re-evaluates the grid at most once (not per frame).
    @Binding var request: PhotoItem?

    @State private var cardFrames: [String: CGRect] = [:]
    @State private var heroPhase: HeroPhase = .idle
    @State private var heroOpenID: String?
    @State private var heroFlightRect: CGRect = .zero
    @State private var heroImage: UIImage?
    @State private var loadedHeroVersion: String?
    @State private var heroFlightBorder: CGFloat = 4
    @State private var heroFlightBottomBorder: CGFloat = 4
    @State private var heroFlightRadius: CGFloat = 0
    @State private var openedCornerGeometry: PhotoCornerGeometry?
    @State private var heroDidLandOpen = false
    @State private var sessionOpacity: Double = 0
    @State private var cardOpacity: Double = 0

    /// Preview card border thickness, mirroring `PreviewPageView.sideBorder`.
    private var heroCardBorder: CGFloat {
        (12 * model.borderWidth.scale).rounded()
    }

    private var heroCardBottomBorder: CGFloat {
        heroCardBorder
    }

    var body: some View {
        ZStack {
            if let openID = heroOpenID, let current = model.selected {
                ZStack {
                    PhotoPreviewView(
                        model: model,
                        current: current,
                        namespace: namespace,
                        sessionOpacity: sessionOpacity,
                        cardOpacity: cardOpacity,
                        isSessionOpen: heroPhase == .open,
                        cornerGeometry: { cornerGeometry(for: $0) },
                        onSelectionChanged: { id in model.previewCurrentID = id },
                        onClose: { drag, scale, id in closeHero(dragOffset: drag, scale: scale, id: id) }
                    )

                    if heroPhase == .openFlying || heroPhase == .closeFlying {
                        HeroFlightView(
                            image: heroImage,
                            rect: heroFlightRect,
                            borderColor: Theme.frame,
                            borderWidth: heroFlightBorder,
                            bottomBorderWidth: heroFlightBottomBorder,
                            cornerRadius: heroFlightRadius
                        )
                        .transition(.identity)
                    }
                }
                .ignoresSafeArea()
                .onChange(of: cardFrames) { _, frames in
                    guard heroPhase == .openFlying, !heroDidLandOpen,
                          let card = frames[openID] else { return }
                    startOpenFlight(to: card)
                }
                .task(id: heroImageRequestKey) {
                    guard let id = model.previewCurrentID,
                          let item = model.allItems.first(where: { $0.id == id }) else { return }
                    // The exact request the preview page's progressive stream
                    // makes for its final frame, so both share one cache entry.
                    let scale = UIScreen.main.scale
                    let target = CGSize(width: screen.width * scale, height: screen.height * scale)
                    if let img = await ImageLoader.shared.previewFrame(
                        asset: item.asset, targetPixelSize: target) {
                        guard !Task.isCancelled, model.previewCurrentID == id else { return }
                        heroImage = img
                        loadedHeroVersion = item.contentVersion
                    }
                }
            }
        }
        .onPreferenceChange(HeroCardFrameKey.self) { cardFrames = $0 }
        .onChange(of: request) { _, item in
            guard let item else { return }
            request = nil
            open(item)
        }
    }

    /// Restarts the hero image request when the previewed photo or its
    /// content changes; content versions alone are not unique across assets.
    private var heroImageRequestKey: String? {
        guard let id = model.previewCurrentID,
              let item = model.allItems.first(where: { $0.id == id }) else { return nil }
        return "\(item.id)|\(item.contentVersion)"
    }

    private func open(_ item: PhotoItem) {
        guard heroPhase == .idle else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let source = frameStore.cells[item.id].flatMap { $0.contentVersion == item.contentVersion ? $0 : nil }
        // Take off immediately with the exact pixels the grid is showing; the
        // high-quality frame lands from the session's own load task below.
        let cached = ImageLoader.shared.bestCachedImage(for: item.asset)
        heroOpenID = item.id
        heroImage = cached
        loadedHeroVersion = cached == nil ? nil : item.contentVersion
        if let source {
            heroFlightBorder = source.border
            heroFlightBottomBorder = source.bottomBorder
            heroFlightRadius = source.cornerRadius
            openedCornerGeometry = source.cornerGeometry
            heroFlightRect = frameStore.screenRect(for: source.rect)
        } else {
            heroFlightBorder = 0
            heroFlightBottomBorder = 0
            heroFlightRect = CGRect(x: screenCenter().x - 40, y: screenCenter().y - 40,
                                    width: 80, height: 80)
            openedCornerGeometry = PhotoCornerGeometry(
                referenceWidth: max(screen.width - 40, 1),
                cornerRadius: model.photoCornerRadius.value
            )
            heroFlightRadius = openedCornerGeometry?.radius(for: heroFlightRect.size) ?? 0
        }
        heroDidLandOpen = false
        sessionOpacity = 0
        cardOpacity = 0
        cardFrames = [:]
        heroPhase = .openFlying
        model.previewCurrentID = item.id
        model.selected = item
        previewPerformanceLogger.debug("Takeoff prepared in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms, cached: \(cached != nil)")

        if cached == nil {
            // Nothing cached for this photo (e.g. its cell was scrolled away):
            // a small local frame still makes the flight start quickly.
            Task { @MainActor in
                let img = await ImageLoader.shared.thumbnail(
                    asset: item.asset,
                    size: CGSize(width: 320, height: 320),
                    contentMode: .aspectFit,
                    allowsNetworkAccess: false)
                guard !Task.isCancelled, heroOpenID == item.id, heroImage == nil else { return }
                heroImage = img
                loadedHeroVersion = img == nil ? nil : item.contentVersion
            }
        }
    }

    private func startOpenFlight(to card: CGRect) {
        heroDidLandOpen = true
        withAnimation(.easeOut(duration: 0.32)) { sessionOpacity = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            heroFlightRect = card
            heroFlightBorder = heroCardBorder
            heroFlightBottomBorder = heroCardBottomBorder
            heroFlightRadius = previewCornerRadius(for: heroOpenID, size: card.size)
        } completion: {
            withAnimation(.easeInOut(duration: 0.14)) {
                cardOpacity = 1
            } completion: {
                heroPhase = .open
            }
        }
    }

    private func closeHero(dragOffset: CGSize, scale: CGFloat, id: String) {
        guard heroPhase == .open else { return }
        // A content update may still be loading a new flight bitmap. Fading is
        // safer than flying an old orientation back into a newly sized cell.
        if let item = model.allItems.first(where: { $0.id == id }),
           loadedHeroVersion != item.contentVersion {
            withAnimation(.easeOut(duration: 0.25)) {
                sessionOpacity = 0
                cardOpacity = 0
            } completion: { finishClose() }
            return
        }
        let rest = cardFrames[id]
        let landingID = model.gridCellID(forItemID: id)
        let version = model.allItems.first(where: { $0.id == landingID })?.contentVersion
        let dest = frameStore.cells[landingID].flatMap { $0.contentVersion == version ? $0 : nil }

        // Plain fade when we have no card geometry or no landing cell (e.g. the
        // photo was just deleted): degrade gracefully to A.
        guard let rest, let dest else {
            withAnimation(.easeOut(duration: 0.25)) {
                sessionOpacity = 0
                cardOpacity = 0
            } completion: { finishClose() }
            return
        }

        let visual = rest.scaledAboutCenter(scale).offsetBy(dragOffset)
        heroFlightRect = visual
        heroFlightBorder = heroCardBorder * scale
        heroFlightBottomBorder = heroCardBottomBorder * scale
        heroFlightRadius = previewCornerRadius(for: id, size: rest.size) * scale
        heroPhase = .closeFlying
        // Hide the live card instantly (not a fade): the flight layer already
        // sits at the exact same visual rect, so this swap is seamless and no
        // neighbouring TabView page can flash through during a cross-fade.
        cardOpacity = 0
        withAnimation(.easeOut(duration: 0.4)) { sessionOpacity = 0 }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            heroFlightRect = frameStore.screenRect(for: dest.rect)
            heroFlightBorder = dest.border
            heroFlightBottomBorder = dest.bottomBorder
            heroFlightRadius = dest.cornerRadius
        } completion: {
            finishClose()
        }
    }

    private func finishClose() {
        model.selected = nil
        model.previewCurrentID = nil
        heroOpenID = nil
        heroImage = nil
        loadedHeroVersion = nil
        heroPhase = .idle
        heroDidLandOpen = false
        openedCornerGeometry = nil
        sessionOpacity = 0
        cardOpacity = 0
    }

    private func screenCenter() -> CGPoint {
        let b = UIScreen.main.bounds
        return CGPoint(x: b.midX, y: b.midY)
    }

    private func cornerGeometry(for id: String) -> PhotoCornerGeometry? {
        frameStore.cells[id]?.cornerGeometry ?? openedCornerGeometry
    }

    private func previewCornerRadius(for id: String?, size: CGSize) -> CGFloat {
        guard let id else { return 0 }
        return cornerGeometry(for: id)?.radius(for: size) ?? model.photoCornerRadius.value
    }
}
