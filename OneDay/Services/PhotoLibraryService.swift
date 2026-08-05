import Photos
import Foundation

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

    func authorize() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return current
    }

    /// Reads the user-configured list of album titles that should be treated
    /// as "subscribed shared albums". Used by `sharedCloudAssetIDs(...)` to
    /// match `.albumRegular` collections whose `localizedTitle` is one of
    /// these names (a workaround for iOS surfacing subscribed shared albums
    /// locally as plain user albums that lack the `.albumCloudShared` bit).
    private static let sharedAlbumNamesKey = "OneDay.sharedAlbumNames"

    static func sharedSubscribedTitles() -> [String] {
        UserDefaults.standard.stringArray(forKey: sharedAlbumNamesKey) ?? []
    }

    static func setSharedSubscribedTitles(_ titles: [String]) {
        let normalized = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(normalized, forKey: sharedAlbumNamesKey)
    }

    /// Returns the titles of all `.albumRegular` collections in the user's
    /// library, sorted alphabetically. Used by the settings UI to present a
    /// toggle list of albums the user can mark as "shared".
    func allRegularAlbumTitles() -> [String] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        var titles: [String] = []
        collections.enumerateObjects { collection, _, _ in
            if let title = collection.localizedTitle, !title.isEmpty {
                titles.append(title)
            }
        }
        return titles.sorted { $0.localizedCompare($1) == .orderedAscending }
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
    /// Enumeration paths:
    /// 1. `.album` + `.albumCloudShared` — the standard iCloud Shared Album
    ///    subtype, covering both albums the user owns and albums they
    ///    subscribe to (a friend created it and invited them).
    /// 2. `.album` + `.albumRegular` with title matching — a fallback for the
    ///    rare case where a shared album surfaces as a plain user album;
    ///    only active when the user configures `subscribedTitles`.
    ///
    /// `nonisolated` + `static` so it is safe to call from a `Task.detached`
    /// off the main actor. All Photos fetch APIs used here are thread-safe.
    nonisolated static func sharedAlbumAssets(subscribedTitles: [String] = []) -> [PHAsset] {
        let normalizedTargets = subscribedTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var assets: [PHAsset] = []

        func absorb(_ collection: PHAssetCollection) {
            let result = PHAsset.fetchAssets(in: collection, options: nil)
            result.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted {
                    assets.append(asset)
                }
            }
        }

        // Path 1: iCloud Shared Albums (owned + subscribed).
        let shared = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil)
        shared.enumerateObjects { collection, _, _ in absorb(collection) }

        // Path 2: title-matched regular albums (fallback).
        if !normalizedTargets.isEmpty {
            let regular = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil)
            regular.enumerateObjects { collection, _, _ in
                guard let raw = collection.localizedTitle else { return }
                let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !title.isEmpty else { return }
                let matched = normalizedTargets.contains { target in
                    title.contains(target) || target.contains(title)
                }
                if matched { absorb(collection) }
            }
        }

        return assets
    }

    /// Asset identifiers that live in any iCloud Shared Album, derived from
    /// `sharedAlbumAssets(subscribedTitles:)`. Used by the day view model to
    /// re-tag already-loaded items when the user changes the shared-album
    /// configuration, without a full refetch.
    func sharedCloudAssetIDs(subscribedTitles: [String] = []) async -> Set<String> {
        await Task.detached(priority: .userInitiated) {
            Set(Self.sharedAlbumAssets(subscribedTitles: subscribedTitles)
                .map(\.localIdentifier))
        }.value
    }

    /// Distinct calendar days (start-of-day) that contain at least one eligible asset, excluding today.
    func eligibleDays() async -> [Date] {
        let subscribedTitles = Self.sharedSubscribedTitles()
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "NOT ((mediaSubtype & %d) != 0)",
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var days = Set<Date>()

            func consider(_ asset: PHAsset) {
                guard let date = asset.creationDate else { return }
                guard MediaFilter.isEligible(asset) else { return }
                let day = calendar.startOfDay(for: date)
                if day < today { days.insert(day) }
            }

            // General library.
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                consider(asset)
            }

            // Shared albums are invisible to the general fetch above, so merge
            // them in explicitly. Without this, days that contain only
            // shared-album photos never appear in the timeline.
            for asset in Self.sharedAlbumAssets(subscribedTitles: subscribedTitles) {
                consider(asset)
            }

            return days.sorted(by: >)
        }.value
    }

    func randomPastDay() async -> Date? {
        await eligibleDays().randomElement()
    }

    /// Build the "time rewind" tunnel group: the most recent eligible day up to and
    /// including today, plus `randomCount` random other eligible days, each day
    /// contributing `photosPerDay` random photos. The first day is the anchor (today
    /// if it has eligible photos, otherwise the nearest past day). The remaining
    /// days are returned in an unspecified order; the caller applies the user's
    /// sort order (reverse or random).
    func rewindGroup(
        randomCount: Int,
        minPhotos: Int,
        photosPerDay: ClosedRange<Int>
    ) async -> [(date: Date, assets: [PHAsset])] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d AND NOT ((mediaSubtype & %d) != 0)",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var groups: [Date: [PHAsset]] = [:]

            result.enumerateObjects { asset, _, _ in
                guard MediaFilter.isEligible(asset) else { return }
                guard let date = asset.creationDate else { return }
                let day = calendar.startOfDay(for: date)
                guard day <= today else { return }
                groups[day, default: []].append(asset)
            }

            // Anchor: the most recent day that has at least one eligible photo.
            let allDaysDesc = groups.keys.sorted(by: >)
            guard let anchorDay = allDaysDesc.first else { return [] }

            // Other days must have enough photos to look good in the tunnel.
            let candidateDays = allDaysDesc.filter { $0 != anchorDay && groups[$0]!.count >= minPhotos }
            let randomPicked = candidateDays.shuffled().prefix(min(randomCount, candidateDays.count))

            let selectedDays = [anchorDay] + randomPicked
            return selectedDays.map { day in
                let all = groups[day]!
                let count = Int.random(in: photosPerDay)
                let chosen = all.shuffled().prefix(min(count, all.count))
                return (date: day, assets: Array(chosen))
            }
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
        let current = Calendar.current.startOfDay(for: date)
        return days.first { $0 < current }
    }

    /// Nearest eligible day strictly later than `date` (today is already excluded).
    func nearestEligibleDay(after date: Date) async -> Date? {
        let days = await eligibleDays() // sorted descending (newest first)
        let current = Calendar.current.startOfDay(for: date)
        return days.last { $0 > current }
    }

    /// Calendar days that share the reference month/day. Each year contributes up to
    /// `photoLimit` random still photos; membership stays stable for this result.
    func todayInHistory(referenceDate: Date = Date(), photoLimit: Int = 3) async -> [TodayInHistoryEntry] {
        let subscribedTitles = Self.sharedSubscribedTitles()
        let sharedIDs = await sharedCloudAssetIDs(subscribedTitles: subscribedTitles)
        let groups = await Task.detached(priority: .userInitiated) { [sharedIDs] in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "NOT ((mediaSubtype & %d) != 0)",
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let calendar = Calendar.current
            let reference = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            guard let referenceMonth = reference.month,
                  let referenceDay = reference.day else { return [(Date, Int, [PHAsset], [PHAsset])]() }

            var assetsByDate: [Date: [PHAsset]] = [:]
            var seen = Set<String>()

            func consider(_ asset: PHAsset) {
                guard MediaFilter.isEligible(asset), let date = asset.creationDate else { return }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard components.month == referenceMonth,
                      components.day == referenceDay else { return }
                guard seen.insert(asset.localIdentifier).inserted else { return }
                let day = calendar.startOfDay(for: date)
                assetsByDate[day, default: []].append(asset)
            }

            result.enumerateObjects { asset, _, _ in consider(asset) }

            // Shared-album photos are invisible to the general fetch; merge them.
            for asset in Self.sharedAlbumAssets(subscribedTitles: subscribedTitles) {
                consider(asset)
            }

            return assetsByDate.keys.sorted(by: >).map { date in
                let allAssets = assetsByDate[date] ?? []
                let selected = allAssets
                    .filter { $0.mediaType == .image }
                    .shuffled()
                    .prefix(min(photoLimit, allAssets.filter { $0.mediaType == .image }.count))
                    .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                let year = calendar.component(.year, from: date)
                return (date, year, allAssets, Array(selected))
            }
        }.value

        var entries: [TodayInHistoryEntry] = []
        for (date, year, allAssets, selectedAssets) in groups {
            let allItems = PhotoItem.build(from: allAssets, sharedIDs: sharedIDs)
            let placeText = await PhotoRoute.placeText(for: allItems)
            entries.append(TodayInHistoryEntry(
                date: date,
                year: year,
                placeText: placeText,
                photos: PhotoItem.build(from: selectedAssets, sharedIDs: sharedIDs),
                totalMediaCount: allAssets.count
            ))
        }
        return entries
    }

    func items(on day: Date) async -> [PhotoItem] {
        let subscribedTitles = Self.sharedSubscribedTitles()
        return await Task.detached(priority: .userInitiated) {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@ AND NOT ((mediaSubtype & %d) != 0)",
                start as NSDate, end as NSDate,
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

            var seen = Set<String>()
            var generalAssets: [PHAsset] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard MediaFilter.isEligible(asset) else { return }
                if seen.insert(asset.localIdentifier).inserted {
                    generalAssets.append(asset)
                }
            }

            // Shared-album photos are absent from the general fetch above.
            // Merge in any that fall on this day. These are filtered in code
            // (not via predicate) because shared collections do not reliably
            // honor complex fetch predicates. Their localIdentifiers form the
            // shared-tag set so PhotoItem marks them with the shared badge.
            let sharedAssets = Self.sharedAlbumAssets(subscribedTitles: subscribedTitles)
            let sharedIDs = Set(sharedAssets.map(\.localIdentifier))
            for asset in sharedAssets {
                guard let date = asset.creationDate, date >= start, date < end else { continue }
                guard MediaFilter.isEligible(asset) else { continue }
                if seen.insert(asset.localIdentifier).inserted {
                    generalAssets.append(asset)
                }
            }

            let sorted = generalAssets.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            return PhotoItem.build(from: sorted, sharedIDs: sharedIDs)
        }.value
    }
}
