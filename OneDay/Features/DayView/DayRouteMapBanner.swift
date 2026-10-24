import SwiftUI
import MapKit
import CoreLocation

/// Full-width trajectory map banner shown at the top of the photo page.
/// Renders an unmodified system map snapshot in the selected native style,
/// with the day's trajectory drawn on a Canvas in the brand blues.
/// The bottom 40% fades to transparent via a linear
/// mask so the map dissolves into the page. Below the map, a location track text
/// shows the sequence of stop names; when there are
/// multiple stops, each dot is enlarged and drawn with its sequence number.
struct DayRouteMapBanner: View {
    let locations: [CLLocation]
    /// Route stop centroids (one dot per stop) to avoid hundreds of dots.
    let stopCoordinates: [CLLocationCoordinate2D]
    /// Display names for each stop (resolved titles, or "……" / "地点 N"
    /// placeholders), used to render the location track text below the map.
    let stopNames: [String]
    let mapStyle: RouteMapStyle
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
        let points = (coordinates + stopCoordinates)
            .map { "\($0.latitude),\($0.longitude)" }
            .joined(separator: ";")
        return "\(mapStyle.rawValue)-\(locations.count)-\(points)-\(Int(size.width))x\(Int(size.height))"
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
        PlaceTrackFlow {
            ForEach(Array(stopNames.enumerated()), id: \.offset) { index, title in
                HStack(alignment: .top, spacing: 6) {
                    // One line per stop; foreign names show their Chinese
                    // translation instead of a bilingual stack.
                    Text(PlaceNaming.TitleLines(title).chinesePreferred)
                        .lineLimit(1)
                    if index < stopNames.count - 1 { Text("→") }
                }
            }
        }
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
        options.mapType = mapStyle.mapType
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
        guard let result, !Task.isCancelled else { return }
        let lines = coordinates.map { result.point(for: $0) }
        let stops = stopCoordinates.map { result.point(for: $0) }
        await MainActor.run {
            guard !Task.isCancelled else { return }
            self.snapshot = result.image
            self.linePoints = lines
            self.stopPoints = stops
        }
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
