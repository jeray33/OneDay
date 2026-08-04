import SwiftUI
import UIKit

/// Full-screen cover with collage, scattered, and minimal editorial layouts.
/// Background is the vibrant tint of the first cover photo.
struct DayCoverView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID? = nil
    var dateIsSource: Bool = false
    var onClose: (() -> Void)? = nil

    @State private var scatteredAppeared = false
    @State private var driftSettled = false

    var body: some View {
        ZStack {
            model.coverBackgroundColor.ignoresSafeArea()

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    switch model.coverMode {
                    case .collage:
                        // Overlapping collage: photos, stickers and the map patch
                        // sit close together with slight overlaps (no gaps).
                        photosLayer(in: size)
                        stickersLayer(in: size)

                        if model.hasAnyLocation {
                            TornPaperMapPatch(locations: model.routeLocations)
                                .frame(width: size.width * 0.6)
                                .rotationEffect(.degrees(-2.5))
                                .position(x: size.width * 0.54, y: size.height * 0.78)
                        }

                        dateBlock
                            .frame(maxWidth: .infinity)
                            .position(x: size.width / 2, y: size.height * 0.22)

                        infoLine
                            .frame(width: size.width)
                            .position(x: size.width / 2, y: size.height * 0.94)
                    case .scattered:
                        scatteredPhotosLayer(in: size)

                        dateBlock
                            .frame(maxWidth: .infinity)
                            .position(x: size.width / 2, y: size.height * 0.5)

                        infoLine
                            .frame(width: size.width)
                            .position(x: size.width / 2, y: size.height * 0.94)
                    case .minimal:
                        minimalCover(in: size)
                    }
                }
            }
            .environment(\.colorScheme, model.coverColorScheme)

            if let onClose {
                DayTopBar(model: model, onClose: onClose, tint: foregroundTint)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let fromTunnel = model.scatteredInitialDrift != .zero
            scatteredAppeared = false
            driftSettled = false
            if fromTunnel {
                withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
                    scatteredAppeared = true
                    driftSettled = true
                }
            } else if !model.scatteredCoverPhotos.isEmpty {
                triggerScatteredEnter()
            }
        }
        .onChange(of: model.scatteredCoverPhotos.count) { _, count in
            if count > 0, !scatteredAppeared, model.scatteredInitialDrift == .zero {
                triggerScatteredEnter()
            }
        }
    }

    private func triggerScatteredEnter() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
            scatteredAppeared = true
        }
    }

    // MARK: Date

    private var dateBlock: some View {
        VStack(spacing: 6) {
            if let caption = DateText.coverCaption(model.date) {
                Text(caption)
                    .font(Theme.serif(20, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(foregroundTint)
            }
            Text(DateText.dottedDate(model.date))
                .font(model.coverDateFont.font(58))
                .foregroundStyle(foregroundTint)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .modifier(OptionalMatchedDate(namespace: dateNamespace, isSource: dateIsSource))
            Text(DateText.weekday(model.date))
                .font(Theme.serif(16))
                .tracking(4)
                .foregroundStyle(foregroundTint.opacity(0.75))
        }
        .padding(.horizontal, 20)
    }

    // MARK: Minimal cover

    private func minimalCover(in size: CGSize) -> some View {
        let titleSize = min(size.width * 0.145, 58)
        let photoWidth = min(size.width * 0.46, size.height * 0.22)

        return ZStack {
            VStack(spacing: 0) {
                minimalCoverMark
                    .frame(width: min(size.width * 0.14, 56),
                           height: min(size.width * 0.14, 56))
                Spacer()
                    .frame(height: max(size.height * 0.025, 14))
                Text(DateText.dottedDate(model.date))
                    .font(model.coverDateFont.font(titleSize))
                    .foregroundStyle(foregroundTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .modifier(OptionalMatchedDate(namespace: dateNamespace, isSource: dateIsSource))
                Text("Recap")
                    .font(model.coverDateFont.font(titleSize))
                    .foregroundStyle(foregroundTint)
                    .lineLimit(1)
            }
            .frame(width: size.width - 40)
            .position(x: size.width / 2, y: size.height * 0.27)

            if let photo = model.minimalCoverPhoto {
                PhotoFrameView(
                    item: photo,
                    width: photoWidth,
                    border: max(photoWidth * 0.035, 6) * model.borderWidth.scale,
                    borderColor: model.frameColor(for: photo),
                    polaroid: model.borderStyle.isPolaroid,
                    shadowLevel: model.photoShadow
                )
                .position(x: size.width / 2, y: size.height * 0.69)
            }

            minimalInfoBlock
                .frame(width: size.width - 40)
                .position(x: size.width / 2, y: size.height * 0.91)
        }
    }

    @ViewBuilder
    private var minimalCoverMark: some View {
        if let image = UIImage(named: "MinimalCoverMark") {
            Image(uiImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(foregroundTint)
        } else {
            Image(systemName: "leaf.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(foregroundTint)
                .accessibilityHidden(true)
        }
    }

    private var minimalInfoBlock: some View {
        VStack(spacing: 5) {
            if let caption = DateText.coverCaption(model.date) {
                Text(caption)
                    .font(Theme.serif(13, weight: .medium))
                    .foregroundStyle(foregroundTint)
            }
            if let secondary = secondaryText {
                Text(secondary)
                    .font(Theme.serif(13, weight: .medium))
                    .foregroundStyle(foregroundTint)
            }
            if !countsText.isEmpty {
                Text(countsText)
                    .font(Theme.serif(13, weight: .medium))
                    .foregroundStyle(foregroundTint)
            }
        }
        .multilineTextAlignment(.center)
    }

    // MARK: Info line (counts / distance / first & last place)

    private var infoLine: some View {
        VStack(spacing: 5) {
            Text(countsText)
                .font(Theme.serif(13, weight: .medium))
                .foregroundStyle(foregroundTint)
            if let secondary = secondaryText {
                Text(secondary)
                    .font(Theme.serif(12))
                    .foregroundStyle(foregroundTint.opacity(0.8))
            }
        }
        .multilineTextAlignment(.center)
    }

    private var countsText: String {
        var parts: [String] = []
        if model.photoCount > 0 { parts.append("\(model.photoCount) 张照片") }
        if model.videoCount > 0 { parts.append("\(model.videoCount) 段视频") }
        return parts.joined(separator: " · ")
    }

    private var secondaryText: String? {
        var parts: [String] = []
        let km = model.travelKilometers
        if km >= 0.05 {
            parts.append(km >= 1 ? String(format: "行程 %.1f 公里", km)
                                 : String(format: "行程 %.0f 米", km * 1000))
        }
        let places = model.headerPlaces
        if let first = places.first {
            if let last = places.last, last != first {
                parts.append("\(first) → \(last)")
            } else {
                parts.append(first)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Photos

    @ViewBuilder
    private func photosLayer(in size: CGSize) -> some View {
        let photos = model.coverPhotos
        if photos.count == 1 {
            photoView(photos[0],
                      anchor: CGPoint(x: size.width / 2, y: size.height * 0.5),
                      width: size.width * 0.62)
        } else if photos.count >= 2 {
            photoView(photos[0],
                      anchor: CGPoint(x: size.width * 0.4, y: size.height * 0.48),
                      width: size.width * 0.56)
            photoView(photos[1],
                      anchor: CGPoint(x: size.width * 0.63, y: size.height * 0.61),
                      width: size.width * 0.5)
        }
    }

    private func photoView(_ item: PhotoItem, anchor: CGPoint, width: CGFloat) -> some View {
        PhotoFrameView(item: item,
                       width: width,
                       border: max(width * 0.035, 6) * model.borderWidth.scale,
                       borderColor: model.frameColor(for: item),
                       polaroid: model.borderStyle.isPolaroid,
                       shadowLevel: model.photoShadow)
            .rotationEffect(.degrees(stableAngle(for: item.id)))
            .shadow(color: .black.opacity(0.28 * Double(model.photoShadow.scale)),
                    radius: 12 * model.photoShadow.scale,
                    x: 0,
                    y: 8 * model.photoShadow.scale)
            .position(anchor)
    }

    // MARK: Person stickers

    @ViewBuilder
    private func stickersLayer(in size: CGSize) -> some View {
        let stickers = model.personStickers
        let anchors: [CGPoint] = [
            CGPoint(x: size.width * 0.72, y: size.height * 0.4),
            CGPoint(x: size.width * 0.3, y: size.height * 0.62)
        ]
        ForEach(Array(stickers.prefix(2).enumerated()), id: \.element.id) { idx, sticker in
            PersonStickerView(sticker: sticker,
                              maxHeight: size.height * 0.17,
                              shadowLevel: model.photoShadow)
                .rotationEffect(.degrees(stableAngle(for: sticker.id) * 0.8))
                .position(anchors[idx % anchors.count])
        }
    }

    // MARK: Scattered photos

    @ViewBuilder
    private func scatteredPhotosLayer(in size: CGSize) -> some View {
        let ref = Double(min(size.width, size.height)) * 0.5
        let spread = model.scatteredSpreadFactor
        ForEach(Array(model.scatteredCoverPhotos.enumerated()), id: \.element.id) { idx, photo in
            let screenR = photo.radius * spread * ref
            let drift = driftSettled ? .zero : model.scatteredInitialDrift
            let x = size.width / 2 + drift.width + cos(photo.angle) * screenR
            let y = size.height / 2 + drift.height + sin(photo.angle) * screenR
            let border = max(photo.baseSize.width * 0.035, 6) * model.borderWidth.scale
            let totalWidth = photo.baseSize.width + 2 * border
            PhotoFrameView(item: photo.item,
                           width: totalWidth,
                           border: border,
                           borderColor: model.frameColor(for: photo.item),
                           polaroid: model.borderStyle.isPolaroid,
                           shadowLevel: model.photoShadow)
                .shadow(color: .black.opacity(0.28 * Double(model.photoShadow.scale)),
                        radius: 12 * model.photoShadow.scale,
                        x: 0,
                        y: 8 * model.photoShadow.scale)
                .modifier(ScatteredPhotoEnter(
                    appeared: scatteredAppeared,
                    fromTunnel: model.scatteredInitialDrift != .zero,
                    index: idx))
                .position(x: x, y: y)
        }
    }

    // MARK: Helpers

    private var foregroundTint: Color {
        model.coverColorScheme == .dark ? Color(white: 0.95) : Color(white: 0.14)
    }

    /// Stable pseudo-random angle in [-6°, 6°] derived from an id hash.
    private func stableAngle(for id: String) -> Double {
        let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let n = (hash % 1201) - 600        // -600...600
        return Double(n) / 100.0           // -6.0...6.0
    }
}

/// Applies the shared date matched-geometry effect only when a namespace is
/// supplied, so the timeline date can fly onto the cover.
private struct OptionalMatchedDate: ViewModifier {
    var namespace: Namespace.ID?
    var isSource: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "flowDate", in: namespace, isSource: isSource)
        } else {
            content
        }
    }
}

/// Scattered photo entrance: tunnel source skips scale/opacity (only drift
/// settles), non-tunnel source springs in with a staggered scale + fade.
private struct ScatteredPhotoEnter: ViewModifier {
    let appeared: Bool
    let fromTunnel: Bool
    let index: Int

    func body(content: Content) -> some View {
        if fromTunnel {
            // 隧道来源：无 scale/opacity 动画，仅靠 drift 归位 + 交叉淡入
            content
        } else {
            // 非隧道来源：弹性缩放入场
            content
                .scaleEffect(appeared ? 1.0 : 0.85)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(.spring(response: 0.7, dampingFraction: 0.82)
                            .delay(Double(index) * 0.06),
                           value: appeared)
        }
    }
}
