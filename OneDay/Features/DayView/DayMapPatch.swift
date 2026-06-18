import SwiftUI
import MapKit
import CoreLocation

/// An editorial map patch tracing the day's real trajectory through located photos,
/// with a heat-style gradient line from first to last shot.
struct DayMapPatch: View {
    let locations: [CLLocation]
    let kilometers: Double

    private var coordinates: [CLLocationCoordinate2D] {
        locations.map(\.coordinate)
    }

    private var heatGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.95, green: 0.78, blue: 0.25),
                     Theme.accent,
                     Color(red: 0.65, green: 0.18, blue: 0.32)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: coordinates, contourStyle: .geodesic)
                .stroke(heatGradient, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

            if let first = coordinates.first {
                Annotation("", coordinate: first) { endpoint(filled: true) }
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Annotation("", coordinate: last) { endpoint(filled: false) }
            }
            ForEach(Array(coordinates.dropFirst().dropLast().enumerated()), id: \.offset) { _, coordinate in
                Annotation("", coordinate: coordinate) {
                    Circle().fill(Theme.accent.opacity(0.7)).frame(width: 6, height: 6)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 180)
        .overlay(alignment: .bottomLeading) { caption }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func endpoint(filled: Bool) -> some View {
        Circle()
            .fill(filled ? Theme.accent : .white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(filled ? .white : Theme.accent, lineWidth: 2.5))
            .shadow(radius: 1.5)
    }

    private var caption: some View {
        Text(distanceText)
            .font(Theme.serif(12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }

    private var distanceText: String {
        if kilometers >= 1 {
            return String(format: "这一天，走过约 %.1f 公里", kilometers)
        }
        if kilometers >= 0.05 {
            return String(format: "这一天，走过约 %.0f 米", kilometers * 1000)
        }
        return "这一天的足迹"
    }

    private var region: MKCoordinateRegion {
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(.world)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.6, 0.01)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
