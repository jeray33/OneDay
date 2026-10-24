import Foundation

/// The small line above the photo cover's date, e.g. "2年前的一天".
nonisolated enum CoverRelativeCaption {
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard day < today else { return "今天" }
        let parts = calendar.dateComponents([.year, .month], from: day, to: today)
        if let years = parts.year, years >= 1 { return "\(years)年前的一天" }
        if let months = parts.month, months >= 1 { return "\(months)个月前的一天" }
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        return days <= 1 ? "昨天" : "\(days)天前的一天"
    }
}
