import SwiftUI
import UIKit

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

/// Live on-screen frames of the photo grid cells, keyed by item id. Kept in a
/// reference type (not `@State`) so the very frequent updates during scrolling
/// mutate it in place without invalidating the SwiftUI body.
final class HeroFrameStore {
    var cells: [String: CGRect] = [:]
}

struct HeroCellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
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
    /// hides it (keeping its layout slot) while its photo is presented.
    func heroCell(id: String, hiddenID: String?) -> some View {
        self
            .opacity(id == hiddenID ? 0 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HeroCellFrameKey.self,
                        value: [id: geo.frame(in: .named(heroCoordinateSpace))]
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
                    .scaledToFill()
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
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
    }
}
