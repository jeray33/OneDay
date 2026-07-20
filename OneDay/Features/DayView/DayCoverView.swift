import SwiftUI

/// Full-screen cover: date, two white-bordered photos with random small tilts,
/// up to two person stickers, and a torn-paper map patch. Background is the
/// vibrant tint of the first cover photo.
struct DayCoverView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID? = nil
    var dateIsSource: Bool = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        ZStack {
            model.coverBackgroundColor.ignoresSafeArea()

            GeometryReader { geo in
                let size = geo.size
                ZStack {
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
                }
            }
            .environment(\.colorScheme, model.coverColorScheme)

            if let onClose {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(foregroundTint)
                                .frame(width: 38, height: 38)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .padding(.trailing, 16)
                        .padding(.top, topSafeAreaInset() + 6)
                    }
                    Spacer()
                }
            }
        }
        .ignoresSafeArea()
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
                       polaroid: model.borderStyle.isPolaroid)
            .rotationEffect(.degrees(stableAngle(for: item.id)))
            .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
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
            PersonStickerView(sticker: sticker, maxHeight: size.height * 0.17)
                .rotationEffect(.degrees(stableAngle(for: sticker.id) * 0.8))
                .position(anchors[idx % anchors.count])
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
