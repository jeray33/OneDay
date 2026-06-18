import CoreLocation

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
