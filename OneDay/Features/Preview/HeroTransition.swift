import SwiftUI
import UIKit
import Photos

/// Shared coordinate space that both the photo grid cells and the preview card
/// measure themselves in, so the flight layer can hand off between them without
/// any jump.
let heroCoordinateSpace = "daySurface"

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
}

/// Live on-screen info of the photo grid cells, keyed by item id. Kept in a
/// reference type (not `@State`) so the very frequent updates during scrolling
/// mutate it in place without invalidating the SwiftUI body.
final class HeroFrameStore {
    var cells: [String: HeroCellInfo] = [:]
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

extension View {
    /// Marks a photo grid cell as a hero source: publishes its live frame and
    /// real border width, and hides it (keeping its layout slot) while its photo
    /// is presented.
    func heroCell(id: String, hiddenID: String?, border: CGFloat) -> some View {
        self
            .opacity(id == hiddenID ? 0 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HeroCellFrameKey.self,
                        value: [id: HeroCellInfo(
                            rect: geo.frame(in: .named(heroCoordinateSpace)),
                            border: border)]
                    )
                }
            )
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

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: max(rect.width - borderWidth * 2, 0),
                           height: max(rect.height - borderWidth * 2, 0))
                    .clipped()
                    .padding(borderWidth)
                    .background(borderColor)
            } else {
                borderColor
            }
        }
        .frame(width: rect.width, height: rect.height)
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
    @State private var heroBorderColor: Color = .white
    @State private var heroSourceBorder: CGFloat = 4
    @State private var heroProgress: CGFloat = 0
    @State private var heroDidLandOpen = false
    @State private var sessionOpacity: Double = 0
    @State private var cardOpacity: Double = 0

    /// Preview card border thickness, mirroring `PreviewPageView.sideBorder`.
    private var heroCardBorder: CGFloat {
        let base = (12 * model.borderWidth.scale).rounded()
        return model.borderStyle.isPolaroid ? max(base, 10) : base
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
                        onSelectionChanged: { id in model.previewCurrentID = id },
                        onClose: { drag, scale, id in closeHero(dragOffset: drag, scale: scale, id: id) }
                    )

                    if heroPhase == .openFlying || heroPhase == .closeFlying {
                        HeroFlightView(
                            image: heroImage,
                            rect: heroFlightRect,
                            borderColor: heroBorderColor,
                            borderWidth: heroSourceBorder + (heroCardBorder - heroSourceBorder) * heroProgress
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
                .task(id: model.previewCurrentID) {
                    guard let id = model.previewCurrentID,
                          let item = model.allItems.first(where: { $0.id == id }) else { return }
                    heroBorderColor = model.frameColor(for: item)
                    if let cell = frameStore.cells[id] { heroSourceBorder = cell.border }
                    if let img = await ImageLoader.shared.thumbnail(
                        asset: item.asset,
                        size: CGSize(width: 1000, height: 1000),
                        highQuality: true,
                        contentMode: .aspectFit) {
                        heroImage = img
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

    private func open(_ item: PhotoItem) {
        guard heroPhase == .idle else { return }
        let source = frameStore.cells[item.id]
        heroImage = nil
        Task {
            let img = await ImageLoader.shared.thumbnail(
                asset: item.asset,
                size: CGSize(width: 1000, height: 1000),
                highQuality: true,
                contentMode: .aspectFit)
            await MainActor.run {
                heroOpenID = item.id
                heroImage = img
                heroBorderColor = model.frameColor(for: item)
                if let source {
                    heroSourceBorder = source.border
                    heroFlightRect = source.rect
                } else {
                    heroSourceBorder = 0
                    heroFlightRect = CGRect(x: screenCenter().x - 40, y: screenCenter().y - 40,
                                            width: 80, height: 80)
                }
                heroProgress = 0
                heroDidLandOpen = false
                sessionOpacity = 0
                cardOpacity = 0
                cardFrames = [:]
                heroPhase = .openFlying
                model.previewCurrentID = item.id
                model.selected = item
            }
        }
    }

    private func startOpenFlight(to card: CGRect) {
        heroDidLandOpen = true
        withAnimation(.easeOut(duration: 0.32)) { sessionOpacity = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            heroFlightRect = card
            heroProgress = 1
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
        let rest = cardFrames[id]
        let dest = frameStore.cells[id]

        // Plain fade when we have no card geometry or no landing cell (e.g. the
        // photo was just deleted): degrade gracefully to A.
        guard let rest else {
            withAnimation(.easeOut(duration: 0.25)) {
                sessionOpacity = 0
                cardOpacity = 0
            } completion: { finishClose() }
            return
        }

        if let dest { heroSourceBorder = dest.border }
        let visual = rest.scaledAboutCenter(scale).offsetBy(dragOffset)
        heroFlightRect = visual
        heroProgress = 1
        heroPhase = .closeFlying
        // Hide the live card instantly (not a fade): the flight layer already
        // sits at the exact same visual rect, so this swap is seamless and no
        // neighbouring TabView page can flash through during a cross-fade.
        cardOpacity = 0
        withAnimation(.easeOut(duration: 0.4)) { sessionOpacity = 0 }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            heroFlightRect = dest?.rect ?? visual
            heroProgress = dest != nil ? 0 : 1
        } completion: {
            finishClose()
        }
    }

    private func finishClose() {
        model.selected = nil
        model.previewCurrentID = nil
        heroOpenID = nil
        heroImage = nil
        heroPhase = .idle
        heroDidLandOpen = false
        heroProgress = 0
        sessionOpacity = 0
        cardOpacity = 0
    }

    private func screenCenter() -> CGPoint {
        let b = UIScreen.main.bounds
        return CGPoint(x: b.midX, y: b.midY)
    }
}
