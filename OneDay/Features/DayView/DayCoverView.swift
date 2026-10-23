import SwiftUI
import UIKit

/// Full-screen minimal cover on a photo-derived pastel background.
struct DayCoverView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID? = nil
    var dateIsSource: Bool = false

    var body: some View {
        ZStack {
            model.coverBackgroundColor.ignoresSafeArea()

            GeometryReader { geo in
                minimalCover(in: geo.size)
            }
            .environment(\.colorScheme, model.coverColorScheme)
        }
        .ignoresSafeArea()
        .task(id: model.instanceID) { await model.prepareEditorial() }
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
                    shared: photo.isFromSharedLibrary,
                    shadowLevel: model.photoShadow,
                    cornerRadius: model.photoCornerRadius.value
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

    private var countsText: String {
        var parts: [String] = []
        if model.coverPhotoCount > 0 { parts.append("\(model.coverPhotoCount) 张照片") }
        if model.coverVideoCount > 0 { parts.append("\(model.coverVideoCount) 段视频") }
        return parts.joined(separator: " · ")
    }

    private var secondaryText: String? {
        var parts: [String] = []
        let km = model.coverTravelKilometers
        if km >= 0.05 {
            parts.append(km >= 1 ? String(format: "行程 %.1f 公里", km)
                                 : String(format: "行程 %.0f 米", km * 1000))
        }
        let places = model.coverPlaces
        if let first = places.first {
            if let last = places.last, last != first {
                parts.append("\(first) → \(last)")
            } else {
                parts.append(first)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private var foregroundTint: Color {
        model.coverForegroundColor
    }
}

/// Applies the shared date matched-geometry effect only when a namespace is
/// supplied, so the timeline date can fly onto the cover.
struct OptionalMatchedDate: ViewModifier {
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
