import SwiftUI
import MapKit
import CoreLocation

/// A torn-paper map patch: a white sheet with jagged, hand-torn edges hosting a
/// monochrome static map with the day's trajectory drawn as a single ink line.
/// Uses `MKMapSnapshotter` (a static image) so there is no interactive "Legal"
/// attribution link, and a single location still renders a map.
struct TornPaperMapPatch: View {
    let locations: [CLLocation]

    @State private var snapshot: UIImage?
    @State private var points: [CGPoint] = []
    @State private var renderedSize: CGSize = .zero

    private var coordinates: [CLLocationCoordinate2D] {
        locations.map(\.coordinate)
    }

    var body: some View {
        if locations.isEmpty {
            EmptyView()
        } else {
            GeometryReader { geo in
                sheet(in: geo.size)
                    .task(id: taskKey(geo.size)) { await makeSnapshot(size: geo.size) }
            }
            .frame(height: 118)
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 4)
        }
    }

    private func taskKey(_ size: CGSize) -> String {
        "\(locations.count)-\(Int(size.width))x\(Int(size.height))"
    }

    private func sheet(in size: CGSize) -> some View {
        let rect = CGRect(origin: .zero, size: size)
        let path = tornPath(in: rect)
        return ZStack {
            path.fill(Color.white)

            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .saturation(0)
                    .opacity(0.9)
                    .clipShape(path)
                inkTrajectory(in: size)
                    .clipShape(path)
            }

            path.stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func inkTrajectory(in size: CGSize) -> some View {
        Canvas { context, _ in
            guard !points.isEmpty else { return }
            if points.count >= 2 {
                var line = Path()
                for (i, p) in points.enumerated() {
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                context.stroke(line, with: .color(inkColor), lineWidth: 2.2)
            }
            if let first = points.first {
                context.fill(Path(ellipseIn: CGRect(x: first.x - 3.5, y: first.y - 3.5, width: 7, height: 7)),
                             with: .color(inkColor))
            }
            if points.count >= 2, let last = points.last {
                context.stroke(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                               with: .color(inkColor), lineWidth: 1.8)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var inkColor: Color { Color(white: 0.16) }

    // MARK: - Snapshot

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
        let pts = coordinates.map { result.point(for: $0) }
        await MainActor.run {
            self.snapshot = result.image
            self.points = pts
            self.renderedSize = size
        }
    }

    // MARK: - Region

    private var region: MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(.world)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // Single location: a tight neighborhood span; otherwise pad the bounds.
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.8, 0.008),
            longitudeDelta: max((maxLon - minLon) * 1.8, 0.008)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Torn-edge path

    /// Builds a closed rectangle with jagged top and bottom edges, seeded deterministically.
    private func tornPath(in rect: CGRect) -> Path {
        let topJagged = jaggedEdge(rect: rect, edgeTop: true, seed: locations.count &+ 7)
        let bottomJagged = jaggedEdge(rect: rect, edgeTop: false, seed: (locations.count &+ 13) * 3)

        var p = Path()
        p.move(to: topJagged[0])
        for pt in topJagged.dropFirst() { p.addLine(to: pt) }   // left → right along top
        for pt in bottomJagged.reversed() { p.addLine(to: pt) }  // right → left along bottom
        p.closeSubpath()
        return p
    }

    private func jaggedEdge(rect: CGRect, edgeTop: Bool, seed: Int) -> [CGPoint] {
        let y: CGFloat = edgeTop ? rect.minY : rect.maxY
        let amp: CGFloat = 5
        let step: CGFloat = 14
        var pts: [CGPoint] = []
        var rng = SplitMix64(state: UInt64(truncatingIfNeeded: seed))
        var x: CGFloat = rect.minX
        while x <= rect.maxX {
            let r = Double(rng.next()) / Double(UInt64.max)
            let r2 = Double(rng.next()) / Double(UInt64.max)
            let offset = CGFloat(r) * amp - amp * 0.5
            let yPt = y + (edgeTop ? offset : -offset)
            let flap: CGFloat = r2 > 0.8 ? (edgeTop ? -2 : 2) : 0
            pts.append(CGPoint(x: x, y: yPt + flap))
            x += step * CGFloat(0.8 + r2 * 0.5)
        }
        if pts.last?.x ?? 0 < rect.maxX {
            pts.append(CGPoint(x: rect.maxX, y: y))
        }
        return pts
    }
}

/// Tiny deterministic PRNG so the torn edges stay stable across redraws.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
