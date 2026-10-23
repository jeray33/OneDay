import SwiftUI
import MapKit
import CoreLocation

/// Full-width trajectory map banner shown at the top of the photo page.
/// Renders an original-color or grayscale `MKMapSnapshotter` image
/// using the user's chosen `MapBlendMode`, with the day's trajectory drawn on a
/// Canvas in the brand blues. The bottom 40% fades to transparent via a linear
/// mask so the map dissolves into the page. Below the map, a location track text
/// shows the sequence of stop names; when there are
/// multiple stops, each dot is enlarged and drawn with its sequence number.
struct DayRouteMapBanner: View {
    let locations: [CLLocation]
    /// Route stop centroids (one dot per stop) to avoid hundreds of dots.
    let stopCoordinates: [CLLocationCoordinate2D]
    /// Display names for each stop (resolved titles, or "定位中…" / "地点 N"
    /// placeholders), used to render the location track text below the map.
    let stopNames: [String]
    /// Whether to keep original colors or blend into the page background.
    let blendMode: MapBlendMode
    /// The page background color used to pre-blend the map snapshot.
    let backgroundColor: Color
    let isDarkPage: Bool
    /// Extra map drawn above the banner's frame, for a parent that reveals
    /// it by clipping. The route stays centered in the banner itself.
    var topExtension: CGFloat = 0

    private static let mapHeight: CGFloat = 240

    @State private var snapshot: UIImage?
    @State private var linePoints: [CGPoint] = []
    @State private var stopPoints: [CGPoint] = []

    private var coordinates: [CLLocationCoordinate2D] {
        locations.map(\.coordinate)
    }

    private var showNumberedDots: Bool { stopPoints.count > 1 }

    var body: some View {
        if locations.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let size = CGSize(width: geo.size.width, height: geo.size.height + topExtension)
                    content(in: size)
                        .task(id: taskKey(size)) { await makeSnapshot(size: size) }
                        .offset(y: -topExtension)
                }
                .frame(height: Self.mapHeight)

                trackText
            }
        }
    }

    private func taskKey(_ size: CGSize) -> String {
        "\(locations.count)-\(stopCoordinates.count)-\(blendMode.rawValue)-\(colorString(backgroundColor))-\(Int(size.width))x\(Int(size.height))"
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)

                trajectoryLayer(in: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // The banner's bottom 40% fades from opaque to transparent,
        // dissolving into the page.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black,
                          location: 1 - 0.4 * Self.mapHeight / max(size.height, Self.mapHeight)),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Trajectory + stop dots

    @ViewBuilder
    private func trajectoryLayer(in size: CGSize) -> some View {
        Canvas { context, _ in
            guard !linePoints.isEmpty else { return }

            if linePoints.count >= 2 {
                var path = Path()
                for (i, p) in linePoints.enumerated() {
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                // Deep-blue outline (0.5pt effective) wrapping the light-blue fill.
                context.stroke(path, with: .color(outlineColor),
                               style: StrokeStyle(lineWidth: 5.0, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(fillColor),
                               style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round))
            }

            for (index, p) in stopPoints.enumerated() {
                let r: CGFloat = showNumberedDots ? 8.0 : 4.5
                let dotRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(fillColor))
                context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 1.5)

                if showNumberedDots {
                    let number = Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    context.draw(number, at: p, anchor: .center)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var trackText: some View {
        Text(stopNames.joined(separator: " → "))
            .font(Theme.serif(12, weight: .regular))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.leading)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outlineColor: Color { Color(red: 0x0C / 255.0, green: 0xAA / 255.0, blue: 0xEE / 255.0) }
    private var fillColor: Color { Color(red: 0x47 / 255.0, green: 0xC7 / 255.0, blue: 0xFF / 255.0) }

    // MARK: Snapshot

    private func makeSnapshot(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let options = MKMapSnapshotter.Options()
        options.mapType = blendMode == .normal ? .mutedStandard : .standard
        options.region = region
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)

        let snapshotter = MKMapSnapshotter(options: options)
        let result: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            snapshotter.start(with: .global(qos: .userInitiated)) { snap, _ in
                cont.resume(returning: snap)
            }
        }
        guard let result else { return }
        let lines = coordinates.map { result.point(for: $0) }
        let stops = stopCoordinates.map { result.point(for: $0) }
        let blended: UIImage
        if blendMode == .normal {
            blended = result.image
        } else {
            let grayscale = grayscaleImage(from: result.image)
            let mode = isDarkPage ? blendMode.darkBlendMode : blendMode.lightBlendMode
            blended = blendImage(grayscale, with: backgroundColor, mode: mode)
        }
        await MainActor.run {
            self.snapshot = blended
            self.linePoints = lines
            self.stopPoints = stops
        }
    }

    /// Desaturates the map snapshot so the map blends cleanly with the page background.
    private func grayscaleImage(from image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Blends the grayscale map snapshot with a solid page background color using
    /// Core Image so the map appears fused into the page, not layered on top of it.
    private func blendImage(_ image: UIImage, with color: Color, mode: BlendMode) -> UIImage {
        guard let inputImage = CIImage(image: image) else { return image }
        let background = solidColorImage(color: UIColor(color), extent: inputImage.extent)

        let filterName: String
        switch mode {
        case .multiply:     filterName = "CIMultiplyCompositing"
        case .screen:       filterName = "CIScreenBlendMode"
        case .overlay:      filterName = "CIOverlayBlendMode"
        case .softLight:    filterName = "CISoftLightBlendMode"
        case .colorBurn:    filterName = "CIColorBurnBlendMode"
        case .colorDodge:   filterName = "CIColorDodgeBlendMode"
        default:            filterName = "CISourceOverCompositing"
        }

        let filter = CIFilter(name: filterName)!
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func solidColorImage(color: UIColor, extent: CGRect) -> CIImage {
        CIImage(color: CIColor(color: color)).cropped(to: extent)
    }

    private func colorString(_ color: Color) -> String {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "unknown" }
        return String(format: "%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }

    // MARK: Region

    private var region: MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(.world)
        }
        let latCenter = (minLat + maxLat) / 2
        let lonCenter = (minLon + maxLon) / 2
        // Pad bounds; keep the trajectory in the upper, non-fading 60% of the
        // banner while leaving a bit more breathing room toward the bottom edge.
        let latDelta = max((maxLat - minLat) * 2.0, 0.008)
        let lonDelta = max((maxLon - minLon) * 1.8, 0.008)
        // The top extension widens the latitude span at the same scale and
        // moves the center north so the banner's own part is unchanged.
        let extensionRatio = topExtension / Self.mapHeight
        let shiftedCenter = CLLocationCoordinate2D(
            latitude: latCenter + latDelta * (0.10 + extensionRatio / 2),
            longitude: lonCenter
        )
        return MKCoordinateRegion(
            center: shiftedCenter,
            span: MKCoordinateSpan(latitudeDelta: latDelta * (1 + extensionRatio),
                                   longitudeDelta: lonDelta)
        )
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
