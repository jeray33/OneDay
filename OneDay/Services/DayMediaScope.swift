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
