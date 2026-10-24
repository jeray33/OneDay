import Foundation

// MARK: - PlaceFields

/// Structured place fields captured from one reverse-geocode result.
/// Deliberately free of CoreLocation types so the naming rules below stay
/// pure and unit-testable; `LocationResolver` bridges a `CLPlacemark` here.
/// `countryCode` carries no display name, so an all-nil set of the other
/// fields counts as "no result".
nonisolated struct PlaceFields: Codable, Equatable, Sendable {
    var areaOfInterest: String?
    var thoroughfare: String?
    var subLocality: String?
    var locality: String?
    var administrativeArea: String?
    var country: String?
    var countryCode: String?
    /// GeoNames and English placemarks cannot use Japanese suffix heuristics.
    var usesDefaultHierarchy: Bool?
    var chineseNames: PlaceHierarchy?

    var isEmpty: Bool {
        areaOfInterest == nil && thoroughfare == nil && subLocality == nil
            && locality == nil && administrativeArea == nil && country == nil
    }
}

// MARK: - Hierarchy

/// One display level of a place, finest to coarsest.
nonisolated enum PlaceLevel: Int, CaseIterable, Comparable, Sendable {
    case poi = 0
    case street = 1
    case district = 2
    case city = 3
    case region = 4
    case country = 5

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A place's names normalized into display levels. Countries put names in
/// different placemark fields, so the mapping is country-specific.
nonisolated struct PlaceHierarchy: Codable, Equatable, Sendable {
    let poi: String?
    let street: String?
    let district: String?
    let city: String?
    let region: String?
    let country: String?

    func name(at level: PlaceLevel) -> String? {
        switch level {
        case .poi:      return poi
        case .street:   return street
        case .district: return district
        case .city:     return city
        case .region:   return region
        case .country:  return country
        }
    }
}

/// The status of one photo's place line, shared by the preview bottom and back.
enum PlaceLineStatus: Equatable, Sendable {
    /// The photo has no location at all.
    case none
    /// Reverse geocoding is still running (or retrying after a transient error).
    case loading
    case resolved
    /// The geocoder confirmed there is no name for this coordinate.
    case unavailable
    /// Transient failures exhausted for this session.
    case failed
}

// MARK: - Naming rules

/// Pure place-naming rules shared by every surface of the app so one photo
/// always carries one name: preview bottom, photo back, day page stops,
/// cover, and history.
nonisolated enum PlaceNaming {
    /// Resolved answers are reused for coordinates within this distance.
    static let reuseMeters: Double = 50
    /// Initial request plus three retries (2 s / 8 s / 30 s backoff).
    static let maxGeocodeAttempts = 4
    static let loadingTitle = "……"
    static let cacheVersion = 4

    enum Resolution: Equatable, Sendable {
        case resolved(PlaceFields)
        case noResult
        case failed
    }

    /// Only two definitive empty results may become a persistent negative
    /// cache entry. A provider's network error must not hide the other result.
    static func combinedResolution(_ primary: Resolution, _ secondary: Resolution) -> Resolution {
        if case .resolved = primary { return primary }
        if case .resolved = secondary { return secondary }
        if primary == .failed || secondary == .failed { return .failed }
        return .noResult
    }

    /// GeoNames supplies a final city/town, not a temporary loading label.
    /// Keep detailed online names and evaluate the offline index only if needed.
    static func withGeoNamesFallback(
        _ resolution: Resolution, lookup: () -> PlaceFields?
    ) -> Resolution {
        switch resolution {
        case .resolved(let fields):
            guard fields.areaOfInterest == nil, fields.thoroughfare == nil,
                  fields.subLocality == nil, fields.locality == nil else { return resolution }
            guard let offline = lookup(), let city = offline.locality, !city.isEmpty else { return resolution }
            var merged = fields
            merged.locality = city
            merged.country = fields.country ?? offline.country
            merged.countryCode = fields.countryCode ?? offline.countryCode
            return .resolved(merged)
        case .noResult, .failed:
            guard let offline = lookup(), let city = offline.locality, !city.isEmpty else { return resolution }
            return .resolved(offline)
        }
    }

    static func resolveWithRetry(
        lookup: @Sendable () async -> Resolution,
        canRetry: @Sendable () async -> Bool = { true },
        wait: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async -> Resolution {
        for attempt in 1...maxGeocodeAttempts {
            guard !Task.isCancelled else { return .failed }
            let result = await lookup()
            guard !Task.isCancelled else { return .failed }
            guard result == .failed, let delay = retryDelay(afterAttempt: attempt) else { return result }
            guard await canRetry() else { return .failed }
            do { try await wait(delay) }
            catch { return .failed }
        }
        return .failed
    }

    /// Background refinement must not erase a usable city or replace it with
    /// a coarser/equally precise spelling. Translation may fill an empty line.
    static func refinedPlace(_ current: StopPlace, with candidate: Resolution) -> StopPlace {
        guard case .resolved(let next) = candidate, !next.isEmpty else {
            if case .resolved = current { return current }
            return .unavailable
        }
        guard case .resolved(let previous) = current else { return .resolved(next) }
        let oldHierarchy = hierarchy(for: previous)
        let newHierarchy = hierarchy(for: next)
        let oldLevel = finestLevel(withNameIn: oldHierarchy) ?? .country
        let newLevel = finestLevel(withNameIn: newHierarchy) ?? .country
        if newLevel < oldLevel { return .resolved(next) }
        if newLevel == oldLevel, previous.chineseNames == nil, next.chineseNames != nil,
           oldHierarchy.name(at: oldLevel) == newHierarchy.name(at: newLevel) {
            return .resolved(next)
        }
        return current
    }

    struct TitleLines: Equatable {
        let primary: String
        let chinese: String?

        init(_ text: String) {
            let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
            primary = lines.first ?? text
            chinese = lines.count > 1 ? lines[1] : nil
        }

        /// Single-line contexts (the map's location track) prefer the Chinese
        /// translation over the native/English name.
        var chinesePreferred: String { chinese ?? primary }
    }

    static func bilingualTitle(_ primary: String, chinese: String?) -> String {
        guard let chinese = chinese?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chinese.isEmpty, chinese != primary,
              chinese.range(of: "\\p{Han}", options: .regularExpression) != nil else { return primary }
        return "\(primary)\n\(chinese)"
    }

    static func attachingChineseNames(_ chinese: PlaceFields, to primary: PlaceFields) -> PlaceFields {
        guard chinese.countryCode == nil || primary.countryCode == nil
                || chinese.countryCode == primary.countryCode else { return primary }
        var result = primary
        var translated = chinese
        translated.usesDefaultHierarchy = primary.usesDefaultHierarchy
        result.chineseNames = hierarchy(for: translated)
        return result
    }

    // MARK: Hierarchy mapping

    static func hierarchy(for fields: PlaceFields) -> PlaceHierarchy {
        if fields.usesDefaultHierarchy == true { return defaultHierarchy(fields) }
        switch fields.countryCode?.uppercased() {
        case "CN": return chineseHierarchy(fields)
        case "JP": return japaneseHierarchy(fields)
        default:   return defaultHierarchy(fields)
        }
    }

    /// China: the district sits in `subLocality` (海淀区) and the city in
    /// `locality` (北京市). Direct-administered municipalities repeat the city
    /// name in `administrativeArea`, which the join deduplicates.
    private static func chineseHierarchy(_ f: PlaceFields) -> PlaceHierarchy {
        PlaceHierarchy(poi: f.areaOfInterest,
                       street: f.thoroughfare,
                       district: f.subLocality,
                       city: f.locality,
                       region: f.administrativeArea,
                       country: f.country)
    }

    /// Japan: for Tokyo's special wards the ward (渋谷区) is `locality` and
    /// the neighborhood (道玄坂) is `subLocality`; for ordinance-designated
    /// cities the city (横浜市) is `locality` and its ward (中区) is
    /// `subLocality`. The 23 wards belong to no city, so city stays nil there.
    private static func japaneseHierarchy(_ f: PlaceFields) -> PlaceHierarchy {
        let district: String?
        if let locality = f.locality, locality.hasSuffix("区") {
            district = locality
        } else if let subLocality = f.subLocality, subLocality.hasSuffix("区") {
            district = subLocality
        } else {
            district = nil
        }

        let city: String?
        if let locality = f.locality, locality.hasSuffix("市") {
            city = locality
        } else {
            city = nil
        }

        let street: String?
        if let subLocality = f.subLocality, subLocality != district {
            street = subLocality
        } else {
            street = f.thoroughfare
        }

        return PlaceHierarchy(poi: f.areaOfInterest,
                              street: street,
                              district: district,
                              city: city,
                              region: f.administrativeArea,
                              country: f.country)
    }

    /// Default (US, Europe, HK, ...): the city is `locality`, the district
    /// (when present) is `subLocality`.
    private static func defaultHierarchy(_ f: PlaceFields) -> PlaceHierarchy {
        PlaceHierarchy(poi: f.areaOfInterest,
                       street: f.thoroughfare,
                       district: f.subLocality,
                       city: f.locality,
                       region: f.administrativeArea,
                       country: f.country)
    }

    // MARK: Single-photo titles

    /// Single-photo title: "most precise name · parent area", e.g.
    /// 颐和园 · 海淀区, 成府路 · 海淀区, 道玄坂 · 渋谷区.
    static func photoTitle(_ fields: PlaceFields) -> String? {
        let h = hierarchy(for: fields)
        guard let level = finestLevel(withNameIn: h) else { return nil }
        guard let name = h.name(at: level) else { return nil }

        // The parent is the enclosing area (district / city / region / country),
        // never the street: 颐和园 · 海淀区, not 颐和园 · 新建宫门路.
        var parent: String?
        for coarser in PlaceLevel.allCases
        where coarser > level && coarser != .street {
            if let candidate = h.name(at: coarser), candidate != name {
                parent = candidate
                break
            }
        }
        return parent.map { "\(name) · \($0)" } ?? name
    }

    /// Administrative line for the photo back: 中国 · 北京市 · 海淀区.
    static func adminLine(_ fields: PlaceFields) -> String? {
        let h = hierarchy(for: fields)
        return joined([h.country, h.region, h.city, h.district])
    }

    private static func finestLevel(withNameIn h: PlaceHierarchy) -> PlaceLevel? {
        for level in PlaceLevel.allCases {
            if let name = h.name(at: level), !name.isEmpty { return level }
        }
        return nil
    }

    /// Joins non-empty parts, dropping each part that repeats the previous
    /// one (so 北京市 · 北京市 collapses to one 北京市).
    static func joined(_ parts: [String?]) -> String? {
        var kept: [String] = []
        for part in parts {
            guard let part, !part.isEmpty, part != kept.last else { continue }
            kept.append(part)
        }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    // MARK: Day-page stop titles

    /// The per-stop resolution state feeding `stopTitles`.
    enum StopPlace: Equatable, Sendable {
        case loading
        case resolved(PlaceFields)
        case unavailable
    }

    /// The computed display title for one stop.
    enum StopTitle: Equatable, Sendable {
        case loading
        case title(String)
        case unavailable
    }

    /// Day-page stop titles. Each stop's precision comes from comparing it
    /// with its neighboring resolved stop (the previous one, or the next one
    /// for the first stop): same district → street, cross-district →
    /// district, cross-city → city. The comparison is local so one far-away
    /// stop never coarsens (and thereby merges) the rest of the day. A POI
    /// (景点) always wins. Stops missing the target level fall back to finer
    /// levels first (a Tokyo ward has no city name, so a cross-city pair
    /// shows 渋谷区), then coarser ones.
    static func stopTitles(for stops: [StopPlace]) -> [StopTitle] {
        let hierarchies: [PlaceHierarchy?] = stops.map { place in
            guard case .resolved(let fields) = place else { return nil }
            return hierarchy(for: fields)
        }

        return stops.indices.map { index in
            switch stops[index] {
            case .loading:
                return .loading
            case .unavailable:
                return .unavailable
            case .resolved(let fields):
                guard let h = hierarchies[index] else { return .unavailable }
                if let poi = h.poi, !poi.isEmpty {
                    return .title(bilingualTitle(poi, chinese: fields.chineseNames?.poi))
                }
                let previous = hierarchies[..<index].compactMap { $0 }.last
                let next = hierarchies[(index + 1)...].lazy.compactMap { $0 }.first
                let neighbor = previous ?? next
                let target = neighbor.map { targetLevel(for: [h, $0]) } ?? .street
                if let name = fallbackName(at: target, in: h) {
                    let level = PlaceLevel.allCases.first { h.name(at: $0) == name }
                    return .title(bilingualTitle(
                        name, chinese: level.flatMap { fields.chineseNames?.name(at: $0) }))
                }
                return .unavailable
            }
        }
    }

    /// Merge adjacent equal names as soon as they resolve, independently of
    /// unrelated loading stops. Revisits and unnamed stops remain separate.
    static func stopGroups(for titles: [StopTitle]) -> [[Int]] {
        var groups: [[Int]] = []
        for index in titles.indices {
            if let last = groups.last?.last,
               case .title(let previous) = titles[last],
               case .title(let current) = titles[index], previous == current {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    private static func targetLevel(for hierarchies: [PlaceHierarchy]) -> PlaceLevel {
        guard !hierarchies.isEmpty else { return .district }
        // Tokyo's wards have no city name, so the region stands in for it.
        let cities = Set(hierarchies.map { $0.city ?? $0.region })
        if cities.count > 1 { return .city }
        let districts = Set(hierarchies.compactMap(\.district))
        if districts.count > 1 { return .district }
        return .street
    }

    private static func fallbackName(at target: PlaceLevel, in h: PlaceHierarchy) -> String? {
        if let name = h.name(at: target), !name.isEmpty { return name }
        // Finer levels first, skipping POI (the caller already prefers it).
        if let finer = firstNamed(in: h, from: max(.street, PlaceLevel(rawValue: max(target.rawValue - 1, 0))!),
                                 downTo: .street) {
            return finer
        }
        // Then coarser levels.
        var level = target
        while level < .country {
            guard let next = PlaceLevel(rawValue: level.rawValue + 1) else { break }
            if let name = h.name(at: next), !name.isEmpty { return name }
            level = next
        }
        return nil
    }

    private static func firstNamed(in h: PlaceHierarchy, from: PlaceLevel, downTo: PlaceLevel) -> String? {
        guard from >= downTo else { return nil }
        if let name = h.name(at: from), !name.isEmpty { return name }
        guard from > downTo, let next = PlaceLevel(rawValue: from.rawValue - 1) else { return nil }
        return firstNamed(in: h, from: next, downTo: downTo)
    }

    // MARK: Geometry helpers

    /// Great-circle distance in meters.
    static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
                * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }

    /// The member point closest to the cluster centroid: a real photo's
    /// coordinate, so a stop resolves where a photo was actually taken
    /// instead of at a mid-air average.
    static func representativeCoordinate(
        of points: [(latitude: Double, longitude: Double)]
    ) -> (latitude: Double, longitude: Double)? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        let count = Double(points.count)
        let centroidLat = points.reduce(0) { $0 + $1.latitude } / count
        let centroidLon = points.reduce(0) { $0 + $1.longitude } / count
        var best = first
        var bestDistance = Double.greatestFiniteMagnitude
        for point in points {
            let distance = haversineMeters(lat1: centroidLat, lon1: centroidLon,
                                           lat2: point.latitude, lon2: point.longitude)
            if distance < bestDistance {
                bestDistance = distance
                best = point
            }
        }
        return best
    }

    // MARK: Cache / retry policy

    /// Index of the closest entry within `maxMeters`, or nil when nothing is
    /// close enough to reuse.
    static func nearestCacheIndex(
        latitude: Double, longitude: Double,
        entries: [(latitude: Double, longitude: Double)],
        maxMeters: Double
    ) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, entry) in entries.enumerated() {
            let distance = haversineMeters(lat1: latitude, lon1: longitude,
                                            lat2: entry.latitude, lon2: entry.longitude)
            if distance <= maxMeters, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Backoff before the next attempt after a transient failure: 2 s, 8 s,
    /// 30 s, then give up for the session. Transient failures are never
    /// cached on disk, so a new launch always gets fresh attempts.
    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: return 2
        case 2: return 8
        case 3: return 30
        default: return nil
        }
    }

    /// A cached "no result" stays valid for one week, then the coordinate is
    /// retried.
    static func noResultIsFresh(
        savedAt: Date, now: Date, ttl: TimeInterval = 7 * 24 * 3600,
        storedVersion: Int = cacheVersion
    ) -> Bool {
        storedVersion == cacheVersion && now.timeIntervalSince(savedAt) < ttl
    }
}
