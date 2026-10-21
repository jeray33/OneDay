import CoreLocation
import Foundation
import MapKit
import os

// MARK: - Placemark bridge

extension PlaceFields {
    /// Bridges a reverse-geocode placemark into the pure naming model,
    /// normalizing whitespace and empty strings to nil.
    init(placemark: CLPlacemark) {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.init(
            areaOfInterest: clean(placemark.areasOfInterest?.first),
            thoroughfare: clean(placemark.thoroughfare),
            subLocality: clean(placemark.subLocality),
            locality: clean(placemark.locality),
            administrativeArea: clean(placemark.administrativeArea),
            country: clean(placemark.country),
            countryCode: clean(placemark.isoCountryCode)
        )
    }
}

// MARK: - Route clustering

/// A chronological location cluster shared by the day cover and Today in History.
struct PhotoRouteSegment: Identifiable {
    let id: String
    let firstItemID: String
    /// A real member photo's coordinate closest to the cluster centroid, so
    /// the stop resolves where a photo was actually taken, not at a mid-air
    /// average that may fall in a river or between two POIs.
    let coordinate: CLLocationCoordinate2D
    let itemIDs: [String]
}

enum PhotoRoute {
    /// Distance from the segment's anchor beyond which a photo starts a new
    /// displayed place. The anchor is the segment's first photo and stays
    /// fixed, so a long walk cannot drag a moving centroid along with it.
    private static let placeThreshold: CLLocationDistance = 300

    static func segments(for items: [PhotoItem]) -> [PhotoRouteSegment] {
        let located = items
            .filter { $0.location != nil }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        guard !located.isEmpty else { return [] }

        var segments: [PhotoRouteSegment] = []
        var members: [PhotoItem] = []
        var anchor: CLLocation?

        func flush() {
            guard let first = members.first else { return }
            let points = members.compactMap { item -> (latitude: Double, longitude: Double)? in
                guard let location = item.location else { return nil }
                return (latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude)
            }
            guard let representative = PlaceNaming.representativeCoordinate(of: points) else { return }
            segments.append(PhotoRouteSegment(
                id: first.id,
                firstItemID: first.id,
                coordinate: CLLocationCoordinate2D(
                    latitude: representative.latitude,
                    longitude: representative.longitude),
                itemIDs: members.map(\.id)
            ))
        }

        for item in located {
            guard let location = item.location else { continue }
            if let anchor, location.distance(from: anchor) > placeThreshold {
                flush()
                members = []
            }
            if members.isEmpty { anchor = location }
            members.append(item)
        }
        flush()
        return segments
    }

    /// First-to-last place text for a day's items (Today in History back
    /// cover). Resolves only the first and the last stop at background
    /// priority, so a heavy history list costs at most two geocode requests
    /// per year.
    static func placeText(for items: [PhotoItem]) async -> String? {
        let allSegments = segments(for: items)
        guard let first = allSegments.first, let last = allSegments.last else { return nil }

        func title(for segment: PhotoRouteSegment) async -> String? {
            let location = CLLocation(latitude: segment.coordinate.latitude,
                                      longitude: segment.coordinate.longitude)
            guard case .resolved(let fields) = await LocationResolver.shared.place(
                for: location, priority: .background) else { return nil }
            return PlaceNaming.photoTitle(fields)
        }

        guard let firstTitle = await title(for: first) else { return nil }
        if last.id == first.id { return firstTitle }
        guard let lastTitle = await title(for: last), lastTitle != firstTitle else { return firstTitle }
        return "\(firstTitle) → \(lastTitle)"
    }
}

extension PlaceNaming.StopPlace {
    /// Maps a resolver outcome to the day page's per-stop state. A transient
    /// failure counts as unavailable: the resolver already retried 2 s / 8 s /
    /// 30 s behind the scenes before returning it.
    init(_ resolution: LocationResolver.Resolution) {
        switch resolution {
        case .resolved(let fields): self = .resolved(fields)
        case .noResult, .failed: self = .unavailable
        }
    }
}

// MARK: - Resolver

/// The single reverse-geocoding gateway for the whole app. Every visible
/// place name (preview bottom, photo back, day page stops, cover, history)
/// resolves through here so one photo always shows one name.
///
/// - Requests run one at a time on a priority queue, throttled to stay well
///   inside Apple's rate limit.
/// - Identical concurrent requests coalesce; a fresh single-shot
///   `CLGeocoder` is created per request, in the user's locale.
/// - Resolved places persist to disk and are reused within 50 m; confirmed
///   "no result" answers persist for a week.
/// - Transient failures (network, rate limit, cancellation) are never
///   cached: they back off 2 s / 8 s / 30 s and then give up for the
///   session, so one bad moment can no longer freeze a name to blank.
actor LocationResolver {
    /// Lower rawValue resolves first.
    enum Priority: Int, Comparable, Sendable {
        case userVisible = 0   // the photo the user is looking at
        case pageContent = 1   // day page stops, cover
        case background = 2    // today in history, rewind

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One reverse-geocode outcome.
    enum Resolution: Sendable {
        case resolved(PlaceFields)
        case noResult
        case failed
    }

    static let shared = LocationResolver()

    // MARK: Tuning

    /// A steady rhythm of ~45 requests per minute.
    private static let minRequestInterval: TimeInterval = 1.4
    private static let cacheVersion = 3

    /// The app ships without zh-Hans localization, so `Locale.current`
    /// falls back to the development region (English). Place names must
    /// follow the system language instead.
    static var geocodeLocale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }
    private static let maxEntries = 600
    /// Poll slice while every queued request waits on a backoff window.
    private static let idlePoll: UInt64 = 400_000_000

    // MARK: State

    private enum EntryKind: Codable, Sendable {
        case fields(PlaceFields)
        case noResult
    }

    private struct CacheEntry: Codable, Sendable {
        let latitude: Double
        let longitude: Double
        let savedAt: Date
        let kind: EntryKind
    }

    private struct CacheFile: Codable {
        let version: Int
        let localeIdentifier: String
        var entries: [CacheEntry]
    }

    private struct Waiter {
        let key: String
        let location: CLLocation
        let priority: Priority
        let order: Int
        let continuation: CheckedContinuation<Resolution, Never>
    }

    private struct FailureRecord {
        var attempts: Int
        var retryAfter: Date?
    }

    private var cache: [CacheEntry] = []
    private var failures: [String: FailureRecord] = [:]
    private var pending: [Waiter] = []
    private var inFlightKey: String?
    private var pumping = false
    private var lastRequestAt: Date?
    private var orderCounter = 0
    private var saveTask: Task<Void, Never>?
    private let cacheURL: URL
    private let logger = Logger(subsystem: "OneDay", category: "LocationResolver")
    private var offlineIndex: OfflinePlaceIndex?
    private var offlineIndexLoaded = false

    init() {
        cacheURL = Self.defaultCacheURL()
        loadCache()
    }

    // MARK: Public API

    /// Resolves a coordinate into structured place fields. Serves from
    /// cache when possible; otherwise queues one geocode request at
    /// `priority` (identical concurrent requests share a single request).
    func place(for location: CLLocation, priority: Priority = .pageContent) async -> Resolution {
        let key = Self.key(for: location.coordinate)

        if let hit = cachedResolution(for: location.coordinate) {
            return withOfflineFallback(hit, at: location.coordinate)
        }
        // Retries exhausted for this coordinate this session.
        if let record = failures[key], record.attempts >= PlaceNaming.maxGeocodeAttempts {
            return .failed
        }
        return await withCheckedContinuation { continuation in
            pending.append(Waiter(key: key, location: location, priority: priority,
                                  order: orderCounter, continuation: continuation))
            orderCounter += 1
            if inFlightKey != key {
                // Either the pump is running and will pick this up (possibly
                // coalescing it with the in-flight request), or it must start.
                startPumpIfNeeded()
            }
        }
    }

    /// Convenience: the photo title (e.g. 颐和园 · 海淀区) for one coordinate.
    func photoTitle(for location: CLLocation, priority: Priority = .userVisible) async -> String? {
        guard case .resolved(let fields) = await place(for: location, priority: priority) else {
            return nil
        }
        return PlaceNaming.photoTitle(fields)
    }

    // MARK: Queue

    private func startPumpIfNeeded() {
        guard !pumping else { return }
        pumping = true
        Task { await pump() }
    }

    /// Dequeues one request at a time. A request whose coordinate is inside
    /// a transient-failure backoff window is skipped until its window opens,
    /// so a backing-off stop never blocks fresher requests.
    private func pump() async {
        while true {
            if pending.isEmpty {
                pumping = false
                return
            }
            guard let index = nextEligibleIndex() else {
                try? await Task.sleep(nanoseconds: Self.idlePoll)
                continue
            }
            let waiter = pending.remove(at: index)

            // Defensive: the caller normally short-circuits exhausted keys.
            if let record = failures[waiter.key], record.attempts >= PlaceNaming.maxGeocodeAttempts {
                waiter.continuation.resume(returning: .failed)
                continue
            }

            inFlightKey = waiter.key
            if let last = lastRequestAt {
                let wait = last.addingTimeInterval(Self.minRequestInterval).timeIntervalSince(Date())
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
            lastRequestAt = Date()

            let resolution = withOfflineFallback(await resolve(waiter.location),
                                                 at: waiter.location.coordinate)
            inFlightKey = nil
            waiter.continuation.resume(returning: resolution)

            // Resume requests that coalesced onto this coordinate.
            let dupes = pending.filter { $0.key == waiter.key }
            pending.removeAll { $0.key == waiter.key }
            for dupe in dupes {
                dupe.continuation.resume(returning: resolution)
            }
        }
    }

    /// The highest-priority (then oldest) request not blocked by backoff or
    /// by the in-flight request.
    private func nextEligibleIndex() -> Int? {
        let now = Date()
        var bestIndex: Int?
        var best: (priority: Priority, order: Int)?
        for (index, waiter) in pending.enumerated() {
            if waiter.key == inFlightKey { continue }
            if let record = failures[waiter.key],
               let retryAfter = record.retryAfter, retryAfter > now {
                continue
            }
            let candidate = (waiter.priority, waiter.order)
            if let best, candidate > best { continue }
            best = candidate
            bestIndex = index
        }
        return bestIndex
    }

    // MARK: Geocoding

    private func resolve(_ location: CLLocation) async -> Resolution {
        let key = Self.key(for: location.coordinate)
        // CLGeocoder is a single-shot object: one fresh instance per request.
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Self.geocodeLocale)
            var fields = placemarks.first.map(PlaceFields.init(placemark:))
            if fields?.isEmpty ?? true {
                fields = await mapKitFields(for: location)
            }
            guard let fields, !fields.isEmpty else {
                logger.log("no placemark at \(location.coordinate.latitude, privacy: .private), \(location.coordinate.longitude, privacy: .private)")
                recordNoResult(coordinate: location.coordinate)
                failures[key] = nil
                return .noResult
            }
            recordResolved(fields, coordinate: location.coordinate)
            failures[key] = nil
            return .resolved(fields)
        } catch {
            let error = error as NSError
            // Only an explicit "found no result" is treated as final for a
            // week; network / rate-limit / cancellation errors back off and
            // retry without ever being cached as a blank name.
            // CLGeocoder served by the China-region provider often has no
            // data abroad; MapKit's geocoder covers those coordinates.
            if let fields = await mapKitFields(for: location), !fields.isEmpty {
                recordResolved(fields, coordinate: location.coordinate)
                failures[key] = nil
                return .resolved(fields)
            }
            if error.code == CLError.geocodeFoundNoResult.rawValue
                || error.code == CLError.geocodeFoundPartialResult.rawValue {
                logger.log("no result at \(location.coordinate.latitude, privacy: .private), \(location.coordinate.longitude, privacy: .private) (code \(error.code, privacy: .public))")
                recordNoResult(coordinate: location.coordinate)
                failures[key] = nil
                return .noResult
            }
            let attempt = (failures[key]?.attempts ?? 0) + 1
            let delay = PlaceNaming.retryDelay(afterAttempt: attempt)
            failures[key] = FailureRecord(attempts: attempt,
                                          retryAfter: delay.map { Date().addingTimeInterval($0) })
            logger.warning("geocode failed, attempt \(attempt, privacy: .public), code \(error.code, privacy: .public), domain \(error.domain, privacy: .public)")
            return .failed
        }
    }

    private func mapKitFields(for location: CLLocation) async -> PlaceFields? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = Self.geocodeLocale
        do {
            let items = try await request.mapItems
            return items.first.map { PlaceFields(placemark: $0.placemark) }
        } catch {
            let error = error as NSError
            logger.warning("mapkit geocode failed, code \(error.code, privacy: .public), domain \(error.domain, privacy: .public)")
            return nil
        }
    }

    // MARK: Offline fallback

    /// Fills in a town name from the bundled GeoNames index when the online
    /// geocoder found nothing or only a country. The persistent cache keeps
    /// the online result untouched, so a later successful lookup (e.g. once
    /// the device is outside the China-region provider) still wins.
    private func withOfflineFallback(_ resolution: Resolution,
                                     at coordinate: CLLocationCoordinate2D) -> Resolution {
        switch resolution {
        case .noResult:
            return offlineFields(for: coordinate).map(Resolution.resolved) ?? .noResult
        case .resolved(let fields)
            where fields.areaOfInterest == nil && fields.thoroughfare == nil
                && fields.subLocality == nil && fields.locality == nil:
            guard let offline = offlineFields(for: coordinate) else { return resolution }
            var merged = fields
            merged.locality = offline.locality
            merged.country = fields.country ?? offline.country
            merged.countryCode = fields.countryCode ?? offline.countryCode
            return .resolved(merged)
        default:
            return resolution
        }
    }

    private func offlineFields(for coordinate: CLLocationCoordinate2D) -> PlaceFields? {
        if !offlineIndexLoaded {
            offlineIndexLoaded = true
            let start = Date()
            offlineIndex = Bundle.main.url(forResource: "GeoNamesCities", withExtension: "dat")
                .flatMap(OfflinePlaceIndex.load(from:))
            let elapsed = Date().timeIntervalSince(start)
            logger.log("offline index loaded: \(self.offlineIndex?.count ?? 0, privacy: .public) places in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        }
        guard let place = offlineIndex?.nearest(latitude: coordinate.latitude,
                                                longitude: coordinate.longitude) else { return nil }
        let locale = Self.geocodeLocale
        let name = OfflinePlaceIndex.displayName(
            for: place,
            languageCode: locale.language.languageCode?.identifier ?? "",
            script: locale.language.script?.identifier)
        return PlaceFields(locality: name,
                           country: locale.localizedString(forRegionCode: place.countryCode),
                           countryCode: place.countryCode)
    }

    // MARK: Persistent cache

    private static func key(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func defaultCacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = caches.first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LocationResolverCache.json")
    }

    private func cachedResolution(for coordinate: CLLocationCoordinate2D) -> Resolution? {
        guard let index = nearestCacheIndex(for: coordinate) else { return nil }
        let entry = cache[index]
        switch entry.kind {
        case .fields(let fields):
            return .resolved(fields)
        case .noResult:
            return PlaceNaming.noResultIsFresh(savedAt: entry.savedAt, now: Date()) ? .noResult : nil
        }
    }

    private func nearestCacheIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        PlaceNaming.nearestCacheIndex(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            entries: cache.map { (latitude: $0.latitude, longitude: $0.longitude) },
            maxMeters: PlaceNaming.reuseMeters)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == Self.cacheVersion,
              file.localeIdentifier == Self.geocodeLocale.identifier
        else { return }
        let now = Date()
        cache = file.entries.filter { entry in
            if case .noResult = entry.kind {
                return PlaceNaming.noResultIsFresh(savedAt: entry.savedAt, now: now)
            }
            return true
        }
        trimCache()
    }

    private func trimCache() {
        guard cache.count > Self.maxEntries else { return }
        cache.sort { $0.savedAt > $1.savedAt }
        cache = Array(cache.prefix(Self.maxEntries))
    }

    private func recordResolved(_ fields: PlaceFields, coordinate: CLLocationCoordinate2D) {
        replaceEntry(at: coordinate) { _ in
            CacheEntry(latitude: coordinate.latitude, longitude: coordinate.longitude,
                       savedAt: Date(), kind: .fields(fields))
        }
        scheduleSave()
    }

    private func recordNoResult(coordinate: CLLocationCoordinate2D) {
        replaceEntry(at: coordinate) { _ in
            CacheEntry(latitude: coordinate.latitude, longitude: coordinate.longitude,
                       savedAt: Date(), kind: .noResult)
        }
        scheduleSave()
    }

    /// Inserts or replaces the cache entry covering this coordinate.
    private func replaceEntry(
        at coordinate: CLLocationCoordinate2D,
        _ make: (CacheEntry) -> CacheEntry
    ) {
        if let index = nearestCacheIndex(for: coordinate) {
            cache[index] = make(cache[index])
        } else {
            cache.append(make(CacheEntry(latitude: 0, longitude: 0,
                                         savedAt: Date(), kind: .noResult)))
        }
        trimCache()
    }

    /// Debounced disk write. Transient failures never reach this cache.
    private func scheduleSave() {
        saveTask?.cancel()
        let entries = cache
        let url = cacheURL
        let localeIdentifier = Self.geocodeLocale.identifier
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let file = CacheFile(version: Self.cacheVersion,
                                 localeIdentifier: localeIdentifier,
                                 entries: entries)
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
