import CoreLocation
import Foundation
import MapKit
import os

// MARK: - Placemark bridge

extension PlaceFields {
    /// Bridges a reverse-geocode placemark into the pure naming model,
    /// normalizing whitespace and empty strings to nil.
    nonisolated init(placemark: CLPlacemark) {
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
    /// Call after the day's retrying lookup completes, so a transient failure
    /// never prematurely ends the visible loading state.
    nonisolated init(_ resolution: LocationResolver.Resolution) {
        switch resolution {
        case .resolved(let fields): self = .resolved(fields)
        case .noResult, .failed: self = .unavailable
        }
    }
}

// MARK: - Resolver

nonisolated struct DayPlaceSeed: Sendable {
    let fields: PlaceFields?
    let isForeign: Bool
    let needsOnline: Bool
}

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
    typealias Resolution = PlaceNaming.Resolution

    static let shared = LocationResolver()

    // MARK: Tuning

    /// A steady rhythm of ~45 requests per minute.
    private static let minRequestInterval: TimeInterval = 1.4
    private static let cacheVersion = PlaceNaming.cacheVersion
    private static let providerTimeout: TimeInterval = 10

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
        let id: UUID
        let key: String
        let location: CLLocation
        let priority: Priority
        let order: Int
        let allowsOfflineFallback: Bool
        let localeIdentifier: String?
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
    private var activeWaiter: Waiter?
    private var pumping = false
    private var lastRequestAt: Date?
    private var orderCounter = 0
    private var saveTask: Task<Void, Never>?
    private let cacheURL: URL
    private let logger = Logger(subsystem: "OneDay", category: "LocationResolver")
    private var offlineIndex: OfflinePlaceIndex?
    private var offlineIndexLoaded = false
    /// Language-specific refinements never replace the system-language disk cache.
    private var foreignCaches: [String: [CacheEntry]] = [:]
    private var refinedDayKeys: Set<String> = []

    init() {
        cacheURL = Self.defaultCacheURL()
        cache = Self.loadCache(from: cacheURL)
    }

    /// Explicitly drives retries. A failure record alone only postpones a
    /// future caller; it does not enqueue another lookup.
    func placeWithRetries(
        for location: CLLocation, priority: Priority = .pageContent,
        allowsOfflineFallback: Bool = true, localeIdentifier: String? = nil
    ) async -> Resolution {
        await PlaceNaming.resolveWithRetry(
            lookup: {
                await self.place(for: location, priority: priority,
                                 allowsOfflineFallback: allowsOfflineFallback, localeIdentifier: localeIdentifier)
            },
            canRetry: { await self.canRetry(location, localeIdentifier: localeIdentifier) })
    }

    private func canRetry(_ location: CLLocation, localeIdentifier: String?) -> Bool {
        (failures[Self.key(for: location.coordinate, localeIdentifier: localeIdentifier)]?.attempts ?? 0)
            < PlaceNaming.maxGeocodeAttempts
    }

    // MARK: Public API

    /// Resolves a coordinate into structured place fields. Serves from
    /// cache when possible; otherwise queues one geocode request at
    /// `priority` (identical concurrent requests share a single request).
    func place(
        for location: CLLocation, priority: Priority = .pageContent,
        allowsOfflineFallback: Bool = true, localeIdentifier: String? = nil
    ) async -> Resolution {
        guard !Task.isCancelled else { return .failed }
        let key = Self.key(for: location.coordinate, localeIdentifier: localeIdentifier)

        if let hit = cachedResolution(for: location.coordinate, localeIdentifier: localeIdentifier) {
            return allowsOfflineFallback ? withOfflineFallback(hit, at: location.coordinate) : hit
        }
        // Retries exhausted for this coordinate this session.
        if let record = failures[key], record.attempts >= PlaceNaming.maxGeocodeAttempts {
            return allowsOfflineFallback ? withOfflineFallback(.failed, at: location.coordinate) : .failed
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed)
                    return
                }
                pending.append(Waiter(
                    id: id, key: key, location: location, priority: priority,
                    order: orderCounter, allowsOfflineFallback: allowsOfflineFallback,
                    localeIdentifier: localeIdentifier,
                    continuation: continuation))
                orderCounter += 1
                startPumpIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Read every stop's cache before starting queued network work, so a
    /// later cached stop never waits behind an earlier uncached stop.
    func cachedPlaces(
        for locations: [CLLocation], allowsOfflineFallback: Bool = false
    ) -> [Resolution?] {
        locations.map { location in
            cachedResolution(for: location.coordinate).map {
                allowsOfflineFallback ? withOfflineFallback($0, at: location.coordinate) : $0
            }
        }
    }

    /// Local work only. Every foreign stop gets a usable GeoNames title before
    /// any background request is enqueued.
    func initialDayPlaces(for locations: [CLLocation]) -> [DayPlaceSeed] {
        if refinedDayKeys.count > Self.maxEntries * 2 { refinedDayKeys.removeAll() }
        return locations.map { location in
            let town = offlinePlace(for: location.coordinate)
            let cached = cachedResolution(for: location.coordinate)
            let code = town?.countryCode ?? {
                if case .resolved(let fields) = cached { return fields.countryCode }
                return nil
            }()
            let foreign = code.map { $0.uppercased() != "CN" } ?? false
            if foreign {
                let local = town.map { OfflinePlaceIndex.dayFields(
                    for: $0, script: Self.geocodeLocale.language.script?.identifier) }
                var state: PlaceNaming.StopPlace = local.map(PlaceNaming.StopPlace.resolved) ?? .loading
                if let hit = cachedResolution(for: location.coordinate, localeIdentifier: "en") {
                    state = PlaceNaming.refinedPlace(state, with: hit)
                }
                let fields: PlaceFields?
                if case .resolved(let resolved) = state { fields = resolved } else { fields = nil }
                return DayPlaceSeed(
                    fields: fields, isForeign: true,
                    needsOnline: !refinedDayKeys.contains(Self.key(
                        for: location.coordinate, localeIdentifier: "en")))
            }
            let fields: PlaceFields?
            if case .resolved(let resolved) = cached {
                if case .resolved(let enriched) = withOfflineFallback(.resolved(resolved), at: location.coordinate) {
                    fields = enriched
                } else { fields = resolved }
            } else { fields = nil }
            return DayPlaceSeed(fields: fields, isForeign: false, needsOnline: fields == nil)
        }
    }

    func refineForeignPlace(for location: CLLocation, initial: PlaceFields?) async -> Resolution {
        let result = await placeWithRetries(
            for: location, priority: .background, allowsOfflineFallback: false, localeIdentifier: "en")
        guard !Task.isCancelled else { return .failed }
        let current = initial.map(PlaceNaming.StopPlace.resolved) ?? .loading
        guard case .resolved(var fields) = result else {
            refinedDayKeys.insert(Self.key(for: location.coordinate, localeIdentifier: "en"))
            return result
        }
        fields.usesDefaultHierarchy = true
        guard PlaceNaming.refinedPlace(current, with: .resolved(fields)) != current else {
            refinedDayKeys.insert(Self.key(for: location.coordinate, localeIdentifier: "en"))
            return .resolved(fields)
        }
        // Only ask for a translation when the English result can improve the
        // displayed city. A country-only response causes no second request.
        let translated = await place(
            for: location, priority: .background, allowsOfflineFallback: false,
            localeIdentifier: Self.geocodeLocale.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans")
        guard !Task.isCancelled else { return .failed }
        if case .resolved(let chinese) = translated {
            fields = PlaceNaming.attachingChineseNames(chinese, to: fields)
        }
        recordResolved(fields, coordinate: location.coordinate, localeIdentifier: "en")
        refinedDayKeys.insert(Self.key(for: location.coordinate, localeIdentifier: "en"))
        return .resolved(fields)
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).continuation.resume(returning: .failed)
        } else if let waiter = activeWaiter, waiter.id == id {
            activeWaiter = nil
            waiter.continuation.resume(returning: .failed)
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
                let result = waiter.allowsOfflineFallback
                    ? withOfflineFallback(.failed, at: waiter.location.coordinate) : .failed
                waiter.continuation.resume(returning: result)
                continue
            }

            inFlightKey = waiter.key
            activeWaiter = waiter
            // Earlier requests may have filled a nearby cache entry while this
            // waiter was queued. Cache hits do not consume the throttle slot.
            if let hit = cachedResolution(
                for: waiter.location.coordinate, localeIdentifier: waiter.localeIdentifier) {
                finishRequest(key: waiter.key, resolution: hit)
                continue
            }
            if let last = lastRequestAt {
                let wait = last.addingTimeInterval(Self.minRequestInterval).timeIntervalSince(Date())
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
            if activeWaiter == nil && !pending.contains(where: { $0.key == waiter.key }) {
                inFlightKey = nil
                continue
            }
            lastRequestAt = Date()

            let resolution = await resolve(waiter.location, localeIdentifier: waiter.localeIdentifier)
            finishRequest(key: waiter.key, resolution: resolution)
        }
    }

    private func finishRequest(key: String, resolution: Resolution) {
        let waiters = [activeWaiter].compactMap { $0 } + pending.filter { $0.key == key }
        activeWaiter = nil
        inFlightKey = nil
        pending.removeAll { $0.key == key }
        for waiter in waiters {
            let result = waiter.allowsOfflineFallback
                ? withOfflineFallback(resolution, at: waiter.location.coordinate) : resolution
            waiter.continuation.resume(returning: result)
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

    private func resolve(_ location: CLLocation, localeIdentifier: String?) async -> Resolution {
        guard !Task.isCancelled else { return .failed }
        let key = Self.key(for: location.coordinate, localeIdentifier: localeIdentifier)
        let locale = localeIdentifier.map(Locale.init(identifier:)) ?? Self.geocodeLocale
        let primary = await coreLocationResolution(for: location, locale: locale)
        guard !Task.isCancelled else { return .failed }
        let resolution: Resolution
        if case .resolved = primary {
            resolution = primary
        } else {
            let secondary = await mapKitResolution(for: location, locale: locale)
            guard !Task.isCancelled else { return .failed }
            resolution = PlaceNaming.combinedResolution(primary, secondary)
        }
        switch resolution {
        case .resolved(let fields):
            recordResolved(fields, coordinate: location.coordinate, localeIdentifier: localeIdentifier)
            failures[key] = nil
        case .noResult:
            recordNoResult(coordinate: location.coordinate, localeIdentifier: localeIdentifier)
            failures[key] = nil
        case .failed:
            let attempt = (failures[key]?.attempts ?? 0) + 1
            failures[key] = FailureRecord(
                attempts: attempt,
                retryAfter: PlaceNaming.retryDelay(afterAttempt: attempt).map { Date().addingTimeInterval($0) })
            logger.warning("geocode failed, attempt \(attempt, privacy: .public)")
        }
        return resolution
    }

    private func coreLocationResolution(for location: CLLocation, locale: Locale) async -> Resolution {
        let geocoder = CLGeocoder()
        return await timedResolution {
            await withTaskCancellationHandler {
                guard !Task.isCancelled else { return .failed }
                do {
                    let placemarks = try await geocoder.reverseGeocodeLocation(
                        location, preferredLocale: locale)
                    guard !Task.isCancelled else { return .failed }
                    guard let fields = placemarks.first.map(PlaceFields.init(placemark:)),
                          !fields.isEmpty else { return .noResult }
                    return .resolved(fields)
                } catch {
                    let error = error as NSError
                    if error.domain == kCLErrorDomain,
                       error.code == CLError.geocodeFoundNoResult.rawValue {
                        return .noResult
                    }
                    return .failed
                }
            } onCancel: {
                geocoder.cancelGeocode()
            }
        }
    }

    private func mapKitResolution(for location: CLLocation, locale: Locale) async -> Resolution {
        guard let request = MKReverseGeocodingRequest(location: location) else { return .failed }
        request.preferredLocale = locale
        return await timedResolution {
            await withTaskCancellationHandler {
                guard !Task.isCancelled else { return .failed }
                do {
                    let items = try await request.mapItems
                    guard !Task.isCancelled else { return .failed }
                    guard let fields = items.first.map({ PlaceFields(placemark: $0.placemark) }),
                          !fields.isEmpty else { return .noResult }
                    return .resolved(fields)
                } catch {
                    let error = error as NSError
                    if error.domain == MKErrorDomain, error.code == MKError.placemarkNotFound.rawValue {
                        return .noResult
                    }
                    return .failed
                }
            } onCancel: {
                request.cancel()
            }
        }
    }

    /// Cancel the losing provider operation as well as its timer. Each
    /// operation's cancellation handler cancels the underlying system request.
    private func timedResolution(
        _ operation: @escaping @Sendable () async -> Resolution
    ) async -> Resolution {
        await withTaskGroup(of: Resolution.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.providerTimeout))
                return .failed
            }
            let result = await group.next() ?? .failed
            group.cancelAll()
            return result
        }
    }

    // MARK: Offline fallback

    /// Fills in a town name from the bundled GeoNames index when the online
    /// geocoder failed, found nothing, or returned only a country. The persistent
    /// cache keeps the online result untouched, so a later successful lookup (e.g. once
    /// the device is outside the China-region provider) still wins.
    private func withOfflineFallback(_ resolution: Resolution,
                                     at coordinate: CLLocationCoordinate2D) -> Resolution {
        PlaceNaming.withGeoNamesFallback(resolution) {
            offlineFields(for: coordinate)
        }
    }

    private func offlineFields(for coordinate: CLLocationCoordinate2D) -> PlaceFields? {
        guard let place = offlinePlace(for: coordinate) else { return nil }
        let locale = Self.geocodeLocale
        let name = OfflinePlaceIndex.displayName(
            for: place,
            languageCode: locale.language.languageCode?.identifier ?? "",
            script: locale.language.script?.identifier)
        return PlaceFields(locality: name,
                           country: locale.localizedString(forRegionCode: place.countryCode),
                           countryCode: place.countryCode, usesDefaultHierarchy: true)
    }

    private func offlinePlace(for coordinate: CLLocationCoordinate2D) -> OfflinePlaceIndex.Place? {
        if !offlineIndexLoaded {
            offlineIndexLoaded = true
            let start = Date()
            offlineIndex = Bundle.main.url(forResource: "GeoNamesCities", withExtension: "dat")
                .flatMap(OfflinePlaceIndex.load(from:))
            let elapsed = Date().timeIntervalSince(start)
            logger.log("offline index loaded: \(self.offlineIndex?.count ?? 0, privacy: .public) places in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        }
        return offlineIndex?.nearest(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MARK: Persistent cache

    private static func key(for coordinate: CLLocationCoordinate2D, localeIdentifier: String? = nil) -> String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
            + (localeIdentifier.map { "|\($0)" } ?? "")
    }

    private static func defaultCacheURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        let base = caches.first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LocationResolverCache.json")
    }

    private func cachedResolution(
        for coordinate: CLLocationCoordinate2D, localeIdentifier: String? = nil
    ) -> Resolution? {
        let entries = localeIdentifier.map { foreignCaches[$0] ?? [] } ?? cache
        guard let index = nearestCacheIndex(for: coordinate, entries: entries) else { return nil }
        let entry = entries[index]
        switch entry.kind {
        case .fields(let fields):
            return .resolved(fields)
        case .noResult:
            return PlaceNaming.noResultIsFresh(savedAt: entry.savedAt, now: Date()) ? .noResult : nil
        }
    }

    private func nearestCacheIndex(
        for coordinate: CLLocationCoordinate2D, entries: [CacheEntry]
    ) -> Int? {
        PlaceNaming.nearestCacheIndex(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            entries: entries.map { (latitude: $0.latitude, longitude: $0.longitude) },
            maxMeters: PlaceNaming.reuseMeters)
    }

    private static func loadCache(from url: URL) -> [CacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              (3...Self.cacheVersion).contains(file.version),
              file.localeIdentifier == Self.geocodeLocale.identifier
        else { return [] }
        let now = Date()
        let entries = file.entries.filter { entry in
            if case .noResult = entry.kind {
                // Version 3 could mistake a failed MapKit fallback for a
                // definitive empty result. Keep its precise hits, not misses.
                return PlaceNaming.noResultIsFresh(
                    savedAt: entry.savedAt, now: now, storedVersion: file.version)
            }
            return true
        }
        return Array(entries.sorted { $0.savedAt > $1.savedAt }.prefix(Self.maxEntries))
    }

    private func trimCache() {
        guard cache.count > Self.maxEntries else { return }
        cache.sort { $0.savedAt > $1.savedAt }
        cache = Array(cache.prefix(Self.maxEntries))
    }

    private func recordResolved(
        _ fields: PlaceFields, coordinate: CLLocationCoordinate2D, localeIdentifier: String? = nil
    ) {
        if let localeIdentifier {
            recordForeign(.fields(fields), coordinate: coordinate, localeIdentifier: localeIdentifier)
            return
        }
        replaceEntry(at: coordinate) { _ in
            CacheEntry(latitude: coordinate.latitude, longitude: coordinate.longitude,
                       savedAt: Date(), kind: .fields(fields))
        }
        scheduleSave()
    }

    private func recordNoResult(coordinate: CLLocationCoordinate2D, localeIdentifier: String? = nil) {
        if let localeIdentifier {
            recordForeign(.noResult, coordinate: coordinate, localeIdentifier: localeIdentifier)
            return
        }
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
        if let index = nearestCacheIndex(for: coordinate, entries: cache) {
            cache[index] = make(cache[index])
        } else {
            cache.append(make(CacheEntry(latitude: 0, longitude: 0,
                                         savedAt: Date(), kind: .noResult)))
        }
        trimCache()
    }

    private func recordForeign(
        _ kind: EntryKind, coordinate: CLLocationCoordinate2D, localeIdentifier: String
    ) {
        var entries = foreignCaches[localeIdentifier] ?? []
        let entry = CacheEntry(
            latitude: coordinate.latitude, longitude: coordinate.longitude, savedAt: Date(), kind: kind)
        if let index = nearestCacheIndex(for: coordinate, entries: entries) { entries[index] = entry }
        else { entries.append(entry) }
        if entries.count > Self.maxEntries {
            entries = Array(entries.sorted { $0.savedAt > $1.savedAt }.prefix(Self.maxEntries))
        }
        foreignCaches[localeIdentifier] = entries
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
