import SwiftUI
import UIKit

enum Theme {
    static let paper = Color(white: 0.96)
    /// Primary text color; adapts to the surrounding color scheme (light page vs dark page).
    static let ink = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.95, alpha: 1)
            : UIColor(white: 0.12, alpha: 1)
    })
    static let frame = Color.white
    static let accent = Color(red: 0.78, green: 0.36, blue: 0.24)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

enum PageBackground: String, CaseIterable, Identifiable {
    case paper, dark, warm, dominant
    var id: Self { self }

    var label: String {
        switch self {
        case .paper: return "白色"
        case .dark: return "黑色"
        case .warm: return "暖橙"
        case .dominant: return "照片主色"
        }
    }

    var icon: String {
        switch self {
        case .paper: return "sun.max"
        case .dark: return "moon"
        case .warm: return "circle.righthalf.filled"
        case .dominant: return "paintpalette"
        }
    }
}

enum DateText {
    static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func weekday(_ date: Date) -> String {
        let w = Calendar.current.component(.weekday, from: date)
        return weekdaySymbols[(w - 1) % 7]
    }

    static func components(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Relative distance from `date` to now: years, else months, else days.
    static func relativeCaption(_ date: Date) -> String? {
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date, to: now)
        if let years = parts.year, years >= 1 { return "\(years) 年前" }
        if let months = parts.month, months >= 1 { return "\(months) 个月前" }
        if let days = parts.day, days >= 1 { return "\(days) 天前" }
        return nil
    }
}
