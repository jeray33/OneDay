import Foundation
import Photos

/// Editorial and navigation scopes deliberately accept no display-category selection.
nonisolated enum DayMediaScope {
    static func isSupported(_ type: PHAssetMediaType) -> Bool {
        type == .image || type == .video
    }

    static func editorialItems<Item>(
        from items: [Item],
        mediaType: (Item) -> PHAssetMediaType,
        isOwnSharedContribution: (Item) -> Bool
    ) -> [Item] {
        items.filter { isSupported(mediaType($0)) && !isOwnSharedContribution($0) }
    }

    /// Contributor matching is always enabled, independently of the shared
    /// display toggle. Own shared copies must not duplicate own originals.
    static func bodyItems<Item>(
        from items: [Item], includeShared: Bool,
        isShared: (Item) -> Bool,
        isOwnSharedContribution: (Item) -> Bool
    ) -> [Item] {
        items.filter {
            !isOwnSharedContribution($0) && (includeShared || !isShared($0))
        }
    }

    static func navigationDay(
        for creationDate: Date?, today: Date = Date(), calendar: Calendar = .current
    ) -> Date? {
        guard let creationDate else { return nil }
        let day = calendar.startOfDay(for: creationDate)
        return day < calendar.startOfDay(for: today) ? day : nil
    }

    static func historyDay(
        for creationDate: Date?, referenceDate: Date, calendar: Calendar = .current
    ) -> Date? {
        guard let creationDate else { return nil }
        let reference = calendar.dateComponents([.month, .day], from: referenceDate)
        let candidate = calendar.dateComponents([.month, .day], from: creationDate)
        guard candidate.month == reference.month, candidate.day == reference.day else { return nil }
        return calendar.startOfDay(for: creationDate)
    }

    /// `navigationDay` for a capture already mapped to its day key by
    /// `CaptureClock` (the key is a device-calendar midnight).
    static func navigationDay(
        forDayKey day: Date?, today: Date = Date(), calendar: Calendar = .current
    ) -> Date? {
        guard let day else { return nil }
        return day < calendar.startOfDay(for: today) ? day : nil
    }

    /// `historyDay` for a capture already mapped to its day key: the key's
    /// device-calendar month/day is the capture's local month/day.
    static func historyDay(
        forDayKey day: Date?, referenceDate: Date, calendar: Calendar = .current
    ) -> Date? {
        guard let day else { return nil }
        let reference = calendar.dateComponents([.month, .day], from: referenceDate)
        let candidate = calendar.dateComponents([.month, .day], from: day)
        guard candidate.month == reference.month, candidate.day == reference.day else { return nil }
        return day
    }

    static func previousDay(
        before date: Date, in descendingDays: [Date], calendar: Calendar = .current
    ) -> Date? {
        let day = calendar.startOfDay(for: date)
        return descendingDays.first { $0 < day }
    }

    static func nextDay(
        after date: Date, in descendingDays: [Date], calendar: Calendar = .current
    ) -> Date? {
        let day = calendar.startOfDay(for: date)
        return descendingDays.last { $0 > day }
    }
}

extension Notification.Name {
    nonisolated static let photoLibraryContentChanged = Notification.Name("OneDay.photoLibraryContentChanged")
}
