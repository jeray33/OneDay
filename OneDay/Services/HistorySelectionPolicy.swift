import Foundation

nonisolated enum HistorySelectionPolicy {
    static func selectedIDs(previous: [String], available: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let valid = Set(available)
        var seen = Set<String>()
        var selected: [String] = []
        for id in previous + available where valid.contains(id) && seen.insert(id).inserted {
            selected.append(id)
            if selected.count == limit { break }
        }
        return selected
    }

    static func matchingDays(
        referenceDate: Date, earliest: Date, latest: Date, calendar: Calendar
    ) -> [Date] {
        let first = calendar.component(.year, from: earliest)
        let last = calendar.component(.year, from: latest)
        guard first <= last else { return [] }
        let parts = calendar.dateComponents([.month, .day], from: referenceDate)
        return (first...last).reversed().compactMap { year in
            guard let day = calendar.date(from: DateComponents(
                year: year, month: parts.month, day: parts.day))
            else { return nil }
            // Calendar normalizes Feb 29 to March 1 in non-leap years.
            return DayMediaScope.historyDay(
                forDayKey: day, referenceDate: referenceDate, calendar: calendar)
        }
    }
}
