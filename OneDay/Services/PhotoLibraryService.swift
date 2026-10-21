import Photos
import Foundation
import os

private nonisolated let captureLog = Logger(subsystem: "OneDay", category: "CaptureClock")

struct TodayInHistoryEntry: Identifiable {
    let date: Date
    let year: Int
    let placeText: String?
    let photos: [PhotoItem]
    let totalMediaCount: Int

    var id: Date { date }
}

@MainActor
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    private init() {}

    private var didRegisterObserver = false

    func authorize() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = current
        }
        if status == .authorized || status == .limited {
            registerLibraryObserverIfNeeded()
        }
        return status
    }

    /// Registers (once) for library-change notifications so the shared-album
    /// cache is invalidated when photos/albums change.
    private func registerLibraryObserverIfNeeded() {
        guard !didRegisterObserver else { return }
        didRegisterObserver = true
        PHPhotoLibrary.shared().register(SharedAlbumLibraryObserver.shared)
    }

    var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Returns the actual `PHAsset`s that live in the user's iCloud Shared
    /// Albums, deduplicated by `localIdentifier`.
    ///
    /// CRITICAL: iCloud Shared Album assets are **not** returned by the
    /// general `PHAsset.fetchAssets(with:)` query. They exist in a separate
    /// namespace and are only reachable through their containing
    /// `PHAssetCollection`. This is why simply tagging assets was never enough
    /// — the shared photos never entered the fetch results at all. Every code
    /// path that wants to include shared photos must merge these in explicitly.
    ///
    /// Enumerates `.album` + `.albumCloudShared` collections, which cover both
    /// albums the user owns and shared with others, and albums a friend
    /// created and invited them to subscribe to.
    ///
    /// `nonisolated` + `static` so it is safe to call from a `Task.detached`
    /// off the main actor. All Photos fetch APIs used here are thread-safe.
    nonisolated static func sharedAlbumAssets() -> [PHAsset] {
        var seen = Set<String>()
        var assets: [PHAsset] = []

        let shared = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil)
        shared.enumerateObjects { collection, _, _ in
            let result = PHAsset.fetchAssets(in: collection, options: nil)
            result.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted {
                    assets.append(asset)
                }
            }
        }

        return assets
    }

    /// Capture timestamps (rounded to the second, as epoch seconds) of every
    /// asset in the user's *own* library. iCloud Shared Album assets are not
    /// part of this fetch, so this set represents only photos the user holds
    /// directly.
    ///
    /// Used to tell "photos I contributed to a shared album" apart from
    /// "photos a family member / friend contributed": a shared-album photo
    /// whose capture second matches one of the user's own assets is almost
    /// certainly the user's own upload. Shared albums recompress the image, so
    /// dimensions differ from the original, but the capture time is preserved,
    /// which makes the timestamp the only reliable signal.
    nonisolated static func ownLibraryCreationSeconds() -> Set<Int> {
        var seconds = Set<Int>()
        PHAsset.fetchAssets(with: PHFetchOptions()).enumerateObjects { asset, _, _ in
            if let date = asset.creationDate {
                seconds.insert(Int(date.timeIntervalSince1970.rounded()))
            }
        }
        return seconds
    }

    /// UserDefaults key for the contributor-match test toggle. Kept in sync with
    /// `DayViewModel.sharedContributorMatchKey`.
    nonisolated static let sharedContributorMatchKey = "OneDay.sharedContributorMatch"

    /// All supported-media days, excluding today. Independent from display filters.
    func eligibleDays() async -> [Date] {
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) { [shared] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let clock = CaptureClock.current()
            let calendar = clock.calendar
            let today = calendar.startOfDay(for: Date())
            let started = Date()
            var assets: [PHAsset] = []

            // General library.
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                if DayMediaScope.isSupported(asset.mediaType) { assets.append(asset) }
            }

            // Shared albums are invisible to the general fetch above, so merge
            // them in explicitly. Day listing remains contributor-agnostic.
            assets.append(contentsOf: shared.sharedAssets.filter { DayMediaScope.isSupported($0.mediaType) })

            var days = Set<Date>()
            for entry in clock.days(for: assets) {
                if let day = DayMediaScope.navigationDay(forDayKey: entry.day, today: today, calendar: calendar) {
                    days.insert(day)
                }
            }
            captureLog.log("eligibleDays: \(assets.count, privacy: .public) assets, local=\(clock.isEnabled, privacy: .public), \(Date().timeIntervalSince(started), format: .fixed(precision: 3), privacy: .public)s")
            return days.sorted(by: >)
        }.value
    }

    func randomPastDay() async -> Date? {
        await eligibleDays().randomElement()
    }

    /// Keep every supported candidate, including currently hidden categories.
    /// Date/asset priorities and preview counts stay fixed until a new session.
    func rewindCandidates(photosPerDay: ClosedRange<Int>) async -> RewindCandidateIndex {
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) { [shared] in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let clock = CaptureClock.current()
            let today = clock.calendar.startOfDay(for: Date())
            var groups: [Date: [String]] = [:]
            var assetsByID: [String: PHAsset] = [:]

            var general: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in general.append(asset) }
            // Shared-album captures only lend their zones to unlocated
            // neighbors here, matching what `items(on:)` sees for the same day.
            let neighbors = shared.sharedAssets.filter { DayMediaScope.isSupported($0.mediaType) }
            let entries = clock.days(for: general + neighbors)

            for (asset, entry) in zip(general, entries) {
                guard let day = entry.day, day <= today else { continue }
                groups[day, default: []].append(asset.localIdentifier)
                assetsByID[asset.localIdentifier] = asset
            }

            let days = groups.keys.sorted(by: >).shuffled().map { date in
                TunnelCandidateDay(
                    date: date, assetIdentifiers: groups[date, default: []].shuffled(),
                    previewCount: Int.random(in: photosPerDay)
                )
            }
            return RewindCandidateIndex(days: days, assetsByID: assetsByID)
        }.value
    }

    /// Random eligible photos from across the whole library, for the rewind flash pool.
    func randomAssets(count: Int) async -> [PHAsset] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d AND NOT ((mediaSubtype & %d) != 0)",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            let result = PHAsset.fetchAssets(with: options)
            guard result.count > 0 else { return [] }

            var located: [PHAsset] = []
            var other: [PHAsset] = []
            var seen = Set<Int>()
            var attempts = 0
            let limit = count * 10
            while located.count < count && attempts < limit {
                attempts += 1
                let index = Int.random(in: 0..<result.count)
                if seen.contains(index) { continue }
                seen.insert(index)
                let asset = result.object(at: index)
                guard MediaFilter.isEligible(asset) else { continue }
                if asset.location != nil { located.append(asset) } else { other.append(asset) }
            }
            // Prefer located photos (so place names show), then fill with the rest.
            return Array((located + other).prefix(count))
        }.value
    }

    /// Nearest eligible day strictly earlier than `date`.
    /// Derived from `eligibleDays()` (the same proven source used to pick days),
    /// so the result is always a real, navigable day.
    func nearestEligibleDay(before date: Date) async -> Date? {
        let days = await eligibleDays() // sorted descending (newest first)
        return DayMediaScope.previousDay(before: date, in: days)
    }

    /// Nearest eligible day strictly later than `date` (today is already excluded).
    func nearestEligibleDay(after date: Date) async -> Date? {
        let days = await eligibleDays() // sorted descending (newest first)
        return DayMediaScope.nextDay(after: date, in: days)
    }

    /// Same-month/day entries from all supported media. Shared-album duplicates
    /// contributed by the owner are excluded, regardless of body display settings.
    func todayInHistory(
        referenceDate: Date = Date(),
        photoLimit: Int = 3
    ) async -> [TodayInHistoryEntry] {
        let shared = await SharedAlbumCache.shared.current()
        let (groups, sharedIDs, zoneByID) = await Task.detached(priority: .userInitiated) { [shared] () -> ([(Date, Int, [PHAsset], [PHAsset])], Set<String>, [String: TimeZone]) in
            let sharedToMerge = shared.foreignSharedAssets
            let sharedIDs = Set(sharedToMerge.map(\.localIdentifier))
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let clock = CaptureClock.current()
            let calendar = clock.calendar
            var assetsByDate: [Date: [PHAsset]] = [:]
            var seen = Set<String>()

            var general: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                if DayMediaScope.isSupported(asset.mediaType) { general.append(asset) }
            }
            // Day keys come from the same population as every other entry
            // point (own library plus all shared-album captures).
            let population = general + shared.sharedAssets.filter { DayMediaScope.isSupported($0.mediaType) }
            var dayByID: [String: Date] = [:]
            var zoneByID: [String: TimeZone] = [:]
            for (asset, entry) in zip(population, clock.days(for: population)) {
                if dayByID[asset.localIdentifier] == nil, let day = entry.day {
                    dayByID[asset.localIdentifier] = day
                    zoneByID[asset.localIdentifier] = entry.zone
                }
            }

            func consider(_ asset: PHAsset) {
                guard DayMediaScope.isSupported(asset.mediaType) else { return }
                let key = dayByID[asset.localIdentifier] ?? clock.days(for: [asset]).first?.day
                guard let day = DayMediaScope.historyDay(
                        forDayKey: key, referenceDate: referenceDate, calendar: calendar
                      ) else { return }
                guard seen.insert(asset.localIdentifier).inserted else { return }
                assetsByDate[day, default: []].append(asset)
            }

            general.forEach(consider)

            // Shared-album photos are invisible to the general fetch; merge them.
            for asset in sharedToMerge {
                consider(asset)
            }

            let mapped = assetsByDate.keys.sorted(by: >).map { date in
                let allAssets = assetsByDate[date] ?? []
                let selected = allAssets
                    .shuffled()
                    .prefix(min(photoLimit, allAssets.count))
                    .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                let year = calendar.component(.year, from: date)
                return (date, year, allAssets, Array(selected))
            }
            return (mapped, sharedIDs, zoneByID)
        }.value

        func items(_ assets: [PHAsset]) -> [PhotoItem] {
            var built = PhotoItem.build(from: assets, sharedIDs: sharedIDs)
            for index in built.indices {
                if let zone = zoneByID[assets[index].localIdentifier] {
                    built[index].captureTimeZone = zone
                }
            }
            return built
        }

        var entries: [TodayInHistoryEntry] = []
        for (date, year, allAssets, selectedAssets) in groups {
            let allItems = items(allAssets)
            let placeText = await PhotoRoute.placeText(for: allItems)
            entries.append(TodayInHistoryEntry(
                date: date,
                year: year,
                placeText: placeText,
                photos: items(selectedAssets),
                totalMediaCount: allAssets.count
            ))
        }
        return entries
    }

    /// The capture-local day key of one asset, judged from the same
    /// neighbors `items(on:)` uses, so opening that day always contains it.
    func captureDay(for asset: PHAsset) async -> Date? {
        guard let date = asset.creationDate else { return nil }
        let clock = CaptureClock.current()
        guard clock.isEnabled else { return clock.calendar.startOfDay(for: date) }
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) { [shared] () -> Date? in
            let window = CaptureClock.inferenceWindow
            let lower = date.addingTimeInterval(-window)
            let upper = date.addingTimeInterval(window)
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                lower as NSDate, upper as NSDate
            )
            var population: [PHAsset] = [asset]
            PHAsset.fetchAssets(with: options).enumerateObjects { neighbor, _, _ in
                if MediaFilter.isEligible(neighbor), neighbor.localIdentifier != asset.localIdentifier {
                    population.append(neighbor)
                }
            }
            population += shared.sharedAssets.filter { neighbor in
                guard let time = neighbor.creationDate, time >= lower, time <= upper,
                      neighbor.localIdentifier != asset.localIdentifier else { return false }
                return MediaFilter.isEligible(neighbor)
            }
            return clock.days(for: population).first?.day
        }.value
    }

    func items(on day: Date) async -> [PhotoItem] {
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) { [shared] () -> [PhotoItem] in
            let clock = CaptureClock.current()
            let calendar = clock.calendar
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
            // A capture-local day can sit up to a day off the device-zone day,
            // and unlocated captures need their neighbors, so fetch wider and
            // keep only captures whose own day key is this day.
            let margin = clock.isEnabled ? CaptureClock.fetchMargin : 0
            let windowStart = start.addingTimeInterval(-margin)
            let windowEnd = end.addingTimeInterval(margin)

            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                windowStart as NSDate, windowEnd as NSDate
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

            var generalWindow: [PHAsset] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                if MediaFilter.isEligible(asset) { generalWindow.append(asset) }
            }

            // Shared-album photos are absent from the general fetch above, so
            // merge in every one that falls on this day. These are filtered in
            // code (not via predicate) because shared collections do not
            // reliably honor complex fetch predicates. The shared-tag set marks
            // them with the shared badge; those whose capture timestamp matches
            // the user's own library are flagged as the user's own
            // contributions so the view model can hide them when the
            // contributor-match toggle is on. Both sets come from the cached,
            // library-wide snapshot instead of a per-day full-library scan.
            let sharedWindow = shared.sharedAssets.filter { asset in
                guard let date = asset.creationDate, date >= windowStart, date < windowEnd else { return false }
                return MediaFilter.isEligible(asset)
            }

            let population = generalWindow + sharedWindow
            var seen = Set<String>()
            var generalAssets: [PHAsset] = []
            var zoneByID: [String: TimeZone] = [:]
            for (asset, entry) in zip(population, clock.days(for: population)) where entry.day == start {
                if seen.insert(asset.localIdentifier).inserted {
                    generalAssets.append(asset)
                    zoneByID[asset.localIdentifier] = entry.zone
                }
            }

            let sorted = generalAssets.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            var items = PhotoItem.build(
                from: sorted,
                sharedIDs: shared.sharedAssetIDs,
                ownContributionIDs: shared.ownContributionIDs)
            for index in items.indices {
                items[index].captureTimeZone = zoneByID[sorted[index].localIdentifier] ?? clock.deviceZone
            }
            return items
        }.value
    }
}
