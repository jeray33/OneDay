import Foundation

/// Manually chosen day covers, persisted per local calendar day. A record
/// survives even while its asset is unavailable; the day page falls back to
/// automatic selection until the saved asset reappears.
nonisolated final class ManualCoverStore: @unchecked Sendable {
    static let shared = ManualCoverStore()

    private static let storageKey = "OneDay.manualCovers"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var covers: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        covers = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    /// Local calendar day key ("yyyy-MM-dd"), so a cover follows the day page
    /// grouping rather than any absolute time zone.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return date.description
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func coverID(for date: Date, calendar: Calendar = .current) -> String? {
        lock.withLock { covers[Self.dayKey(for: date, calendar: calendar)] }
    }

    func setCover(_ assetID: String, for date: Date, calendar: Calendar = .current) {
        lock.withLock {
            covers[Self.dayKey(for: date, calendar: calendar)] = assetID
            defaults.set(covers, forKey: Self.storageKey)
        }
    }

    func clear(for date: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(for: date, calendar: calendar)
        lock.withLock {
            guard covers.removeValue(forKey: key) != nil else { return }
            defaults.set(covers, forKey: Self.storageKey)
        }
    }
}
