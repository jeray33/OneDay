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

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var days = Set<Date>()

            func consider(_ asset: PHAsset) {
                guard DayMediaScope.isSupported(asset.mediaType),
                      let day = DayMediaScope.navigationDay(
                        for: asset.creationDate, today: today, calendar: calendar
                      ) else { return }
                days.insert(day)
            }

            // General library.
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                consider(asset)
            }

            // Shared albums are invisible to the general fetch above, so merge
            // them in explicitly. Day listing remains contributor-agnostic.
            for asset in shared.sharedAssets {
                consider(asset)
            }

            return days.sorted(by: >)
        }.value
    }

    func randomPastDay() async -> Date? {
        await eligibleDays().randomElement()
    }

    /// Keep every supported candidate, including currently hidden categories.
    /// Date/asset priorities and preview counts stay fixed until a new session.
    func rewindCandidates(photosPerDay: ClosedRange<Int>) async -> RewindCandidateIndex {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var groups: [Date: [String]] = [:]
            var assetsByID: [String: PHAsset] = [:]

            result.enumerateObjects { asset, _, _ in
                guard let date = asset.creationDate else { return }
                let day = calendar.startOfDay(for: date)
                guard day <= today else { return }
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
        let (groups, sharedIDs) = await Task.detached(priority: .userInitiated) { [shared] () -> ([(Date, Int, [PHAsset], [PHAsset])], Set<String>) in
            let sharedToMerge = shared.foreignSharedAssets
            let sharedIDs = Set(sharedToMerge.map(\.localIdentifier))
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let result = PHAsset.fetchAssets(with: options)

            let calendar = Calendar.current
            var assetsByDate: [Date: [PHAsset]] = [:]
            var seen = Set<String>()

            func consider(_ asset: PHAsset) {
                guard DayMediaScope.isSupported(asset.mediaType),
                      let day = DayMediaScope.historyDay(
                        for: asset.creationDate, referenceDate: referenceDate, calendar: calendar
                      ) else { return }
                guard seen.insert(asset.localIdentifier).inserted else { return }
                assetsByDate[day, default: []].append(asset)
            }

            result.enumerateObjects { asset, _, _ in consider(asset) }

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
            return (mapped, sharedIDs)
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
        let shared = await SharedAlbumCache.shared.current()
        return await Task.detached(priority: .userInitiated) { [shared] () -> [PhotoItem] in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: day)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "creationDate >= %@ AND creationDate < %@",
                start as NSDate, end as NSDate
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

            // Shared-album photos are absent from the general fetch above, so
            // merge in every one that falls on this day. These are filtered in
            // code (not via predicate) because shared collections do not
            // reliably honor complex fetch predicates. The shared-tag set marks
            // them with the shared badge; those whose capture timestamp matches
            // the user's own library are flagged as the user's own
            // contributions so the view model can hide them when the
            // contributor-match toggle is on. Both sets come from the cached,
            // library-wide snapshot instead of a per-day full-library scan.
            for asset in shared.sharedAssets {
                guard let date = asset.creationDate, date >= start, date < end else { continue }
                guard MediaFilter.isEligible(asset) else { continue }
                if seen.insert(asset.localIdentifier).inserted {
                    generalAssets.append(asset)
                }
            }

            let sorted = generalAssets.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            return PhotoItem.build(
                from: sorted,
                sharedIDs: shared.sharedAssetIDs,
                ownContributionIDs: shared.ownContributionIDs)
        }.value
    }
}
