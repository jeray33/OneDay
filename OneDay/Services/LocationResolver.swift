import CoreLocation

/// A chronological location cluster shared by the day cover and Today in History.
struct PhotoRouteSegment: Identifiable {
    let id: String
    let firstItemID: String
    let coordinate: CLLocationCoordinate2D
    let itemIDs: [String]
}

enum PhotoRoute {
    /// Distance beyond which a photo starts a new displayed place.
    private static let placeThreshold: CLLocationDistance = 200

    static func segments(for items: [PhotoItem]) -> [PhotoRouteSegment] {
        let located = items
            .filter { $0.location != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard !located.isEmpty else { return [] }

        var segments: [PhotoRouteSegment] = []
        var ids: [String] = []
        var first: PhotoItem?
        var sumLatitude = 0.0
        var sumLongitude = 0.0

        func centroid() -> CLLocation {
            let count = Double(ids.count)
            return CLLocation(latitude: sumLatitude / count, longitude: sumLongitude / count)
        }
        func flush() {
            guard let first else { return }
            segments.append(PhotoRouteSegment(
                id: first.id,
                firstItemID: first.id,
                coordinate: centroid().coordinate,
                itemIDs: ids
            ))
        }
        func reset() {
            ids = []
            first = nil
            sumLatitude = 0
            sumLongitude = 0
        }
        func add(_ item: PhotoItem, location: CLLocation) {
            if first == nil { first = item }
            ids.append(item.id)
            sumLatitude += location.coordinate.latitude
            sumLongitude += location.coordinate.longitude
        }

        for item in located {
            guard let location = item.location else { continue }
            if !ids.isEmpty, location.distance(from: centroid()) > placeThreshold {
                flush()
                reset()
            }
            add(item, location: location)
        }
        flush()
        return segments
    }

    /// Uses the same route clustering and first-to-last place format as the cover.
    static func placeText(for items: [PhotoItem]) async -> String? {
        var seen = Set<String>()
        var names: [String] = []
        for segment in segments(for: items) {
            let location = CLLocation(
                latitude: segment.coordinate.latitude,
                longitude: segment.coordinate.longitude
            )
            guard let name = await LocationResolver.shared.name(for: location),
                  !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        guard let first = names.first else { return nil }
        guard let last = names.last, last != first else { return first }
        return "\(first) → \(last)"
    }
}

actor LocationResolver {
    static let shared = LocationResolver()
    private var cache: [String: String] = [:]
    private let geocoder = CLGeocoder()

    func name(for location: CLLocation) async -> String? {
        let key = String(format: "%.3f,%.3f", location.coordinate.latitude, location.coordinate.longitude)
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }

        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        let name = placemarks?.first.flatMap { placemark in
            placemark.areasOfInterest?.first
                ?? placemark.subLocality
                ?? placemark.locality
                ?? placemark.name
                ?? placemark.administrativeArea
        }
        cache[key] = name ?? ""
        return name
    }
}
