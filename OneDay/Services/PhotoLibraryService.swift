import Photos
import Foundation

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
