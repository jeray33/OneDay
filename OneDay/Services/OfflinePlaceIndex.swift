import Foundation

/// Offline nearest-town lookup over the GeoNames `cities1000` dump (towns of
/// 1,000+ people, CC BY 4.0). It backs up the online geocoder where it has no
/// data — Apple's China-region provider returns nothing abroad — so a foreign
/// stop still reads as a city or town rather than "地点 N".
nonisolated struct OfflinePlaceIndex: Sendable {
    struct Place: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let countryCode: String
        let population: Int
        /// GeoNames' primary (usually local-language) name.
        let name: String
        /// Han-script alternate names, simplified or traditional, unordered.
        let hanNames: [String]
    }

    /// Beyond this a "nearest town" is no longer a meaningful place name.
    static let maxMeters: Double = 50_000

    private let places: [Place]
    /// 1° × 1° grid cells → indices into `places`.
    private let grid: [Int: [Int]]

    /// Rows are `lat \t lon \t countryCode \t population \t name \t hanNames`
    /// with `hanNames` joined by "|".
    init(tsv: String) {
        var places: [Place] = []
        var grid: [Int: [Int]] = [:]
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 5,
                  let latitude = Double(columns[0]),
                  let longitude = Double(columns[1]) else { continue }
            let hanNames = columns.count > 5
                ? columns[5].split(separator: "|").map(String.init)
                : []
            let place = Place(latitude: latitude, longitude: longitude,
                              countryCode: String(columns[2]),
                              population: Int(columns[3]) ?? 0,
                              name: String(columns[4]),
                              hanNames: hanNames)
            grid[Self.cell(latitude, longitude), default: []].append(places.count)
            places.append(place)
        }
        self.places = places
        self.grid = grid
    }

    /// Loads the bundled raw-deflate-compressed TSV.
    static func load(from url: URL) -> OfflinePlaceIndex? {
        guard let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let tsv = String(data: data, encoding: .utf8) else { return nil }
        return OfflinePlaceIndex(tsv: tsv)
    }

    var count: Int { places.count }

    /// The town a coordinate most plausibly belongs to. Plain nearest-point
    /// would hand a spot inside Paris to whichever suburb's center happens to
    /// be closer than Paris' own, so each town gets an estimated radius from
    /// its population and the smallest "distance past that radius" wins.
    func nearest(latitude: Double, longitude: Double) -> Place? {
        let latSpan = 1
        // Longitude degrees shrink toward the poles; widen the search there.
        let lonSpan = abs(latitude) > 60 ? 3 : (abs(latitude) > 45 ? 2 : 1)
        let baseLat = Int(floor(latitude))
        let baseLon = Int(floor(longitude))

        var best: (score: Double, index: Int)?
        for dLat in -latSpan...latSpan {
            for dLon in -lonSpan...lonSpan {
                var lon = baseLon + dLon
                if lon < -180 { lon += 360 }
                if lon >= 180 { lon -= 360 }
                guard let indices = grid[Self.cellKey(baseLat + dLat, lon)] else { continue }
                for index in indices {
                    let place = places[index]
                    let meters = Self.haversineMeters(latitude, longitude,
                                                      place.latitude, place.longitude)
                    guard meters <= Self.maxMeters else { continue }
                    let score = meters - Self.estimatedRadius(population: place.population)
                    if best == nil || score < best!.score {
                        best = (score, index)
                    }
                }
            }
        }
        return best.map { places[$0.index] }
    }

    /// Roughly 4 m per √inhabitant: Paris (2.1M) ≈ 5.8 km, Nice (340k) ≈
    /// 2.3 km, a 1,000-person village ≈ 130 m.
    static func estimatedRadius(population: Int) -> Double {
        min(8_000, 4 * Double(max(population, 0)).squareRoot())
    }

    // MARK: Display name

    /// Native/local name first, a genuine Han alternate second. No translated
    /// city is attached to a more precise POI or street.
    static func dayFields(for place: Place, script: String?) -> PlaceFields {
        let chinese = place.hanNames.isEmpty ? nil
            : displayName(for: place, languageCode: "zh", script: script)
        return PlaceFields(
            locality: place.name, countryCode: place.countryCode, usesDefaultHierarchy: true,
            chineseNames: chinese.map {
                PlaceHierarchy(poi: nil, street: nil, district: nil, city: $0, region: nil, country: nil)
            })
    }

    /// The name in the user's language: a Han name for Chinese (converted to
    /// the requested script), otherwise GeoNames' local name.
    static func displayName(for place: Place, languageCode: String, script: String?) -> String {
        guard languageCode == "zh", !place.hanNames.isEmpty else { return place.name }
        let wantsTraditional = script == "Hant"
        let toWanted = StringTransform(wantsTraditional ? "Hans-Hant" : "Hant-Hans")
        let toOther = StringTransform(wantsTraditional ? "Hant-Hans" : "Hans-Hant")
        func isWantedScript(_ name: String) -> Bool {
            name.applyingTransform(toWanted, reverse: false) == name
        }
        // GeoNames' Han names carry no language tag, and a region-neutral
        // spelling (康城, the Hong Kong name for Cannes) may precede the
        // mainland one (戛纳). A name that only exists in the requested script
        // is the strongest signal of the requested region's usage.
        if let specific = place.hanNames.first(where: {
            isWantedScript($0) && $0.applyingTransform(toOther, reverse: false) != $0
        }) {
            return specific
        }
        if let neutral = place.hanNames.first(where: isWantedScript) {
            return neutral
        }
        let first = place.hanNames[0]
        return first.applyingTransform(toWanted, reverse: false) ?? first
    }

    // MARK: Grid

    private static func haversineMeters(_ lat1: Double, _ lon1: Double,
                                        _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    private static func cell(_ latitude: Double, _ longitude: Double) -> Int {
        cellKey(Int(floor(latitude)), Int(floor(longitude)))
    }

    private static func cellKey(_ lat: Int, _ lon: Int) -> Int {
        (lat + 90) * 360 + (lon + 180)
    }
}
