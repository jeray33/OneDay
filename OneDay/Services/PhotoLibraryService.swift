import Photos
import Foundation
import os

private nonisolated let captureLog = Logger(subsystem: "OneDay", category: "CaptureClock")

struct TodayInHistoryEntry: Identifiable, Equatable {
    let date: Date
    let year: Int
    let placeText: String?
    let photos: [PhotoItem]
    let totalMediaCount: Int

    var id: Date { date }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.date == rhs.date && lhs.year == rhs.year && lhs.placeText == rhs.placeText
            && lhs.totalMediaCount == rhs.totalMediaCount && lhs.photos.count == rhs.photos.count
            && zip(lhs.photos, rhs.photos).allSatisfy {
                $0.id == $1.id && $0.contentVersion == $1.contentVersion
                    && $0.sharedSource == $1.sharedSource && $0.captureTimeZone == $1.captureTimeZone
            }
    }
}

struct TodayInHistorySnapshot {
    let entries: [TodayInHistoryEntry]
    let itemsByDate: [Date: [PhotoItem]]
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

    /// Captures of the user's *own* library. iCloud Shared Album assets are
    /// not part of the general fetch, so these are only photos the user holds
    /// directly; `SharedCopyMatch` uses them to tell the user's own shared
    /// uploads apart from photos family members or friends contributed.
    nonisolated struct OwnCaptureIndex {
        private var seconds = Set<Int>()
        private var times: [TimeInterval] = []
        private var assets: [PHAsset] = []

        /// Assets must arrive in ascending `creationDate` order.
        mutating func add(_ asset: PHAsset) {
            guard let time = asset.creationDate?.timeIntervalSince1970 else { return }
            seconds.insert(SharedCopyMatch.captureSecond(time))
            times.append(time)
            assets.append(asset)
        }

        func ownContributionIDs(among shared: [PHAsset]) -> Set<String> {
            Set(shared.compactMap { asset in
                guard let time = asset.creationDate?.timeIntervalSince1970,
                      SharedCopyMatch.isOwnCopy(
                        sharedTime: time,
                        isVideo: asset.mediaType == .video,
                        sharedNames: { Self.fileNames(of: asset) },
                        ownSeconds: seconds,
                        ownSortedTimes: times,
                        ownNames: { Self.fileNames(of: assets[$0]) })
                else { return nil }
                return asset.localIdentifier
            })
        }

        private static func fileNames(of asset: PHAsset) -> [String] {
            PHAssetResource.assetResources(for: asset).map(\.originalFilename)
        }
    }

    nonisolated static func ownLibraryCaptureIndex() -> OwnCaptureIndex {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var index = OwnCaptureIndex()
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in index.add(asset) }
        return index
    }


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

    /// Same-month/day entries from all supported media. Shared-album duplicates
    /// contributed by the owner are excluded, regardless of body display settings.
    func todayInHistory(
        referenceDate: Date = Date(),
        photoLimit: Int = 3,
        preserving previous: [TodayInHistoryEntry] = []
    ) async -> TodayInHistorySnapshot {
        let shared = await SharedAlbumCache.shared.current()
        let started = CFAbsoluteTimeGetCurrent()
        let query = Task.detached(priority: .userInitiated) { [shared] () -> [(Date, [PhotoItem])] in
            let clock = CaptureClock.current()
            let calendar = clock.calendar
            func boundary(ascending: Bool) -> Date? {
                let options = PHFetchOptions()
                options.fetchLimit = 1
                options.predicate = NSPredicate(
                    format: "creationDate != nil AND (mediaType == %d OR mediaType == %d)",
                    PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
                return PHAsset.fetchAssets(with: options).firstObject?.creationDate
            }
            let sharedDates = shared.sharedAssets.compactMap(\.creationDate)
            guard let earliest = ([boundary(ascending: true)].compactMap { $0 } + sharedDates).min(),
                  let latest = ([boundary(ascending: false)].compactMap { $0 } + sharedDates).max()
            else { return [] }
            let margin = clock.isEnabled ? CaptureClock.fetchMargin : 0
            let days = HistorySelectionPolicy.matchingDays(
                referenceDate: referenceDate,
                earliest: earliest.addingTimeInterval(-margin),
                latest: latest.addingTimeInterval(margin), calendar: calendar)
            var groups: [(Date, [PhotoItem])] = []
            for day in days {
                guard !Task.isCancelled else { return [] }
                groups.append((day, Self.dayItems(on: day, shared: shared, clock: clock)))
            }
            return groups
        }
        let groups = await withTaskCancellationHandler {
            await query.value
        } onCancel: {
            query.cancel()
        }
        let previousByDate = Dictionary(uniqueKeysWithValues: previous.map { ($0.date, $0) })
        var entries: [TodayInHistoryEntry] = []
        var itemsByDate: [Date: [PhotoItem]] = [:]
        for (date, fetched) in groups {
            let items = fetched.filter { !$0.isOwnSharedContribution }
            guard !items.isEmpty else { continue }
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let selectedIDs = HistorySelectionPolicy.selectedIDs(
                previous: previousByDate[date]?.photos.map(\.id) ?? [],
                available: items.map(\.id), limit: photoLimit)
            itemsByDate[date] = items
            entries.append(TodayInHistoryEntry(
                date: date, year: Calendar.current.component(.year, from: date),
                placeText: previousByDate[date]?.placeText,
                photos: selectedIDs.compactMap { byID[$0] }, totalMediaCount: items.count))
        }
        captureLog.debug("History photos ready in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms; entries: \(entries.count)")
        return TodayInHistorySnapshot(entries: entries, itemsByDate: itemsByDate)
    }

    func resolveHistoryPlaces(
        in snapshot: TodayInHistorySnapshot,
        onUpdate: @MainActor (TodayInHistoryEntry) -> Void
    ) async {
        let started = CFAbsoluteTimeGetCurrent()
        for entry in snapshot.entries {
            guard !Task.isCancelled else { return }
            let placeText = await PhotoRoute.placeText(for: snapshot.itemsByDate[entry.date] ?? [])
            guard !Task.isCancelled else { return }
            guard placeText != entry.placeText else { continue }
            onUpdate(TodayInHistoryEntry(
                date: entry.date, year: entry.year, placeText: placeText,
                photos: entry.photos, totalMediaCount: entry.totalMediaCount))
        }
        captureLog.debug("History places ready in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms")
    }

    func items(on day: Date) async -> [PhotoItem] {
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) {
            Self.dayItems(on: day, shared: shared, clock: CaptureClock.current())
        }.value
    }

    /// One fetch/assignment path for day pages and history, including the
    /// capture-local margin, neighbor zones and own shared-copy matching.
    private nonisolated static func dayItems(
        on day: Date, shared: SharedAlbumCache.Snapshot, clock: CaptureClock
    ) -> [PhotoItem] {
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
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            // Pad by the match tolerance so an own original just outside the
            // window still identifies its shared copy.
            let pad = SharedCopyMatch.tolerance + 1
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                windowStart.addingTimeInterval(-pad) as NSDate, windowEnd.addingTimeInterval(pad) as NSDate
            )
            var generalWindow: [PHAsset] = []
            var ownCaptures = OwnCaptureIndex()
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard let date = asset.creationDate else { return }
                ownCaptures.add(asset)
                if date >= windowStart, date < windowEnd, MediaFilter.isEligible(asset) {
                    generalWindow.append(asset)
                }
            }

            // Shared-album photos are absent from the general fetch above, so
            // merge in every one that falls on this day. These are filtered in
            // code (not via predicate) because shared collections do not
            // reliably honor complex fetch predicates. The shared-tag set marks
            // them with the shared badge; those matching an own capture (see
            // `SharedCopyMatch`) are flagged as the user's own
            // contributions so the view model hides them. Matching against
            // this window's own captures works before the library-wide
            // snapshot finishes its background scan.
            let sharedWindow = shared.sharedAssets.filter { asset in
                guard let date = asset.creationDate, date >= windowStart, date < windowEnd else { return false }
                return MediaFilter.isEligible(asset)
            }
            let unknownWindow = sharedWindow.filter { !shared.ownContributionIDs.contains($0.localIdentifier) }
            let ownContributionIDs = shared.ownContributionIDs.union(
                ownCaptures.ownContributionIDs(among: unknownWindow))

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
                ownContributionIDs: ownContributionIDs)
            for index in items.indices {
                items[index].captureTimeZone = zoneByID[sorted[index].localIdentifier] ?? clock.deviceZone
            }
            return items
    }
}
