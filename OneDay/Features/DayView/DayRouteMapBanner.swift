import SwiftUI
import MapKit
import CoreLocation

/// Full-width, fixed-height trajectory map banner shown at the top of the
/// photo page. Renders a grayscale `MKMapSnapshotter` image blended (multiply
/// on light pages, screen on dark pages) into the page background, with the
/// day's trajectory drawn on a Canvas in the brand blues. The bottom 40%
/// fades to transparent via a linear mask so the map dissolves into the page.
struct DayRouteMapBanner: View {
    let locations: [CLLocation]
    /// Route stop centroids (one dot per stop) to avoid hundreds of dots.
    let stopCoordinates: [CLLocationCoordinate2D]
    let isDarkPage: Bool

    @State private var snapshot: UIImage?
    @State private var linePoints: [CGPoint] = []
    @State private var stopPoints: [CGPoint] = []

    private var coordinates: [CLLocationCoordinate2D] {
        locations.map(\.coordinate)
    }

    var body: some View {
        if locations.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geo in
                content(in: geo.size)
                    .task(id: taskKey(geo.size)) { await makeSnapshot(size: geo.size) }
            }
            .frame(height: 240)
        }
    }

    private func taskKey(_ size: CGSize) -> String {
        "\(locations.count)-\(stopCoordinates.count)-\(Int(size.width))x\(Int(size.height))"
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .saturation(0)
                    .if(isDarkPage) { $0.colorInvert().blendMode(.screen) }
                    .if(!isDarkPage) { $0.blendMode(.multiply) }

                trajectoryLayer(in: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // Bottom 40% fades from opaque to transparent, dissolving into the page.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.6),
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

            for p in stopPoints {
                let r: CGFloat = 4.5
                let dotRect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(fillColor))
                context.stroke(Path(ellipseIn: dotRect), with: .color(.white), lineWidth: 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var outlineColor: Color { Color(red: 0x0C / 255.0, green: 0xAA / 255.0, blue: 0xEE / 255.0) }
    private var fillColor: Color { Color(red: 0x47 / 255.0, green: 0xC7 / 255.0, blue: 0xFF / 255.0) }

    // MARK: Snapshot

    private func makeSnapshot(size: CGSize) async {
        guard size.width > 1, size.height > 1 else { return }
        let options = MKMapSnapshotter.Options()
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
        await MainActor.run {
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
        // Pad bounds; leave ~30% extra latitude headroom toward the south so the
        // trajectory sits in the upper, non-fading 60% of the banner.
        let latDelta = max((maxLat - minLat) * 1.8, 0.008)
        let lonDelta = max((maxLon - minLon) * 1.8, 0.008)
        let shiftedCenter = CLLocationCoordinate2D(
            latitude: latCenter + latDelta * 0.15,
            longitude: lonCenter
        )
        return MKCoordinateRegion(
            center: shiftedCenter,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
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
