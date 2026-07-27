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

    var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Distinct calendar days (start-of-day) that contain at least one eligible asset, excluding today.
    func eligibleDays() async -> [Date] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "NOT ((mediaSubtype & %d) != 0)",
                PHAssetMediaSubtype.photoScreenshot.rawValue
            )
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: options)

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var days = Set<Date>()
            result.enumerateObjects { asset, _, _ in
                guard let date = asset.creationDate else { return }
                guard MediaFilter.isEligible(asset) else { return }
                let day = calendar.startOfDay(for: date)
                if day < today { days.insert(day) }
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
        let groups = await Task.detached(priority: .userInitiated) {
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
            result.enumerateObjects { asset, _, _ in
                guard MediaFilter.isEligible(asset), let date = asset.creationDate else { return }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      components.month == referenceMonth,
                      components.day == referenceDay else { return }
                let day = calendar.startOfDay(for: date)
                assetsByDate[day, default: []].append(asset)
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
            let allItems = allAssets.map(PhotoItem.init(asset:))
            let placeText = await PhotoRoute.placeText(for: allItems)
            entries.append(TodayInHistoryEntry(
                date: date,
                year: year,
                placeText: placeText,
                photos: selectedAssets.map(PhotoItem.init(asset:)),
                totalMediaCount: allAssets.count
            ))
        }
        return entries
    }

    func items(on day: Date) async -> [PhotoItem] {
        await Task.detached(priority: .userInitiated) {
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
            let result = PHAsset.fetchAssets(with: options)

            var items: [PhotoItem] = []
            result.enumerateObjects { asset, _, _ in
                guard MediaFilter.isEligible(asset) else { return }
                items.append(PhotoItem(asset: asset))
            }
            return items
        }.value
    }
}
