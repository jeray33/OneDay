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

/// Sort order for the "rewind" time-travel tunnel: today/newest first, then either
/// descending chronologically (reverse) or shuffled (random).
enum RewindSortOrder: String, CaseIterable, Identifiable {
    case reverse, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .reverse: return "倒序"
        case .random:  return "随机"
        }
    }
    var icon: String {
        switch self {
        case .reverse: return "arrow.down.circle"
        case .random:  return "shuffle.circle"
        }
    }
}

/// How a tap in the tunnel rewind mode behaves.
enum TunnelTapMode: String, CaseIterable, Identifiable {
    case anywhere = "anywhere"
    case photo = "photo"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anywhere: return "点击任意位置"
        case .photo:    return "点击照片"
        }
    }
}

/// What happens to the target day (and every deeper day) right before the tunnel
/// hands off to the day view.
enum TunnelLandingMotion: String, CaseIterable, Identifiable {
    case none = "none"
    case slight = "slight"
    case rushOut = "rushOut"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:    return "默认"
        case .slight:  return "轻微运动"
        case .rushOut: return "冲屏出场"
        }
    }
}

/// Control style for the tunnel rewind mode.
/// Backdrop for the tunnel rewind mode. Dark reads more cinematic (photos pop,
/// depth-of-field + vignette are stronger); light matches the rest of the app.
enum TunnelBackground: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "白色"
        case .dark:  return "深色"
        }
    }
    var icon: String {
        switch self {
        case .light: return "sun.max"
        case .dark:  return "moon.stars"
        }
    }
    var isDark: Bool { self == .dark }
    var color: Color { self == .dark ? Color(white: 0.06) : Theme.paper }
    var scheme: ColorScheme { self == .dark ? .dark : .light }
}

/// How far the tunnel photos spread from the center (tube-wall radius).
enum TunnelSpread: String, CaseIterable, Identifiable {
    case narrowest, narrow, medium, wide, widest
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 2 }
    var label: String { ["最窄", "较窄", "适中", "较宽", "最宽"][idx] }
    /// Multiplier on the reference radius (min(w,h) * 0.5).
    var factor: Double { [0.40, 0.75, 1.10, 1.50, 1.90][idx] }
}

/// Base on-screen size of each tunnel photo at the focus plane.
enum TunnelPhotoScale: String, CaseIterable, Identifiable {
    case smallest, small, medium, large, largest
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 2 }
    var label: String { ["最小", "较小", "适中", "较大", "最大"][idx] }
    /// Base long-side length in points (loader adds a small random jitter).
    var base: CGFloat { [104, 128, 150, 176, 204][idx] }
}

/// Distance between adjacent day planes along the tunnel's depth axis.
enum TunnelDepthSpacing: String, CaseIterable, Identifiable {
    case compact, standard, spacious, deep, farthest
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 1 }
    var label: String { ["紧凑", "标准", "舒展", "深远", "极远"][idx] }
    /// The previous tunnel used one depth unit between days, now represented by
    /// `standard`, so existing visuals remain unchanged by default.
    var factor: Double { [0.72, 1.0, 1.32, 1.68, 2.08][idx] }
}

/// Depth spread among the photos belonging to the same day plane.
enum TunnelPhotoDepthSpacing: String, CaseIterable, Identifiable {
    case clustered, standard, staggered, spacious, deep
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 1 }
    var label: String { ["聚拢", "标准", "错落", "舒展", "深远"][idx] }
    /// One reproduces the previous per-photo depth offsets.
    var factor: Double { [0.45, 1.0, 1.45, 1.95, 2.50][idx] }
}

/// Shared near/far speed difference for travel, ambient drift and device-tilt
/// parallax in the tunnel.
enum TunnelSpeedContrast: String, CaseIterable, Identifiable {
    case calm, gentle, natural, strong, extreme
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 2 }
    var label: String { ["平缓", "柔和", "自然", "强烈", "极致"][idx] }
    /// Applied to projection depth. One reproduces the previous perspective;
    /// larger values make near photos rush faster while far photos drift slower.
    var projectionExponent: Double { [0.72, 0.86, 1.0, 1.18, 1.38][idx] }
}

/// How large a photo may grow before it fades out, i.e. how much it spills past
/// the screen edges.
enum TunnelOverflow: String, CaseIterable, Identifiable {
    case none, slight, medium, more, heavy
    var id: String { rawValue }
    private var idx: Int { Self.allCases.firstIndex(of: self) ?? 2 }
    var label: String { ["不冲屏", "轻微", "适中", "较多", "大幅"][idx] }
    /// Fully visible while scale <= fadeStart; fully gone by fadeEnd.
    var fadeStart: Double { [1.15, 1.25, 1.40, 1.70, 2.40][idx] }
    var fadeEnd: Double { [1.50, 1.75, 2.10, 2.80, 4.20][idx] }
    /// Depth closer than this is culled.
    var nearCull: Double { [0.62, 0.55, 0.46, 0.34, 0.20][idx] }
}

/// Where the "回到" caption + big date sit during the tunnel rewind.
enum TunnelTextPosition: String, CaseIterable, Identifiable {
    case center, bottom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .center: return "居中"
        case .bottom: return "底部"
        }
    }
    var icon: String {
        switch self {
        case .center: return "text.aligncenter"
        case .bottom: return "arrow.down.to.line"
        }
    }
}

/// Display font shared by the cover and time-travel dates.
enum CoverDateFont: String, CaseIterable, Identifiable {
    case impact
    case markerFelt
    case serifBold
    static let storageKey = "OneDay.coverDateFont"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .impact:     return "Impact"
        case .markerFelt: return "Marker Felt"
        case .serifBold:  return "Serif Bold"
        }
    }
    var icon: String { "textformat" }
    func font(_ size: CGFloat) -> Font {
        switch self {
        case .impact:     return .custom("Impact", size: size)
        case .markerFelt: return .custom("MarkerFelt-Wide", size: size)
        case .serifBold:  return Theme.serif(size, weight: .bold)
        }
    }
}

enum DateText {
    static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    /// `timeZone` reads a capture instant in its local zone; day keys use
    /// the default device zone.
    static func weekday(_ date: Date, in timeZone: TimeZone? = nil) -> String {
        let w = calendar(timeZone).component(.weekday, from: date)
        return weekdaySymbols[(w - 1) % 7]
    }

    static func components(_ date: Date, in timeZone: TimeZone? = nil) -> (year: Int, month: Int, day: Int) {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func calendar(_ timeZone: TimeZone?) -> Calendar {
        var calendar = Calendar.current
        if let timeZone { calendar.timeZone = timeZone }
        return calendar
    }

    /// Big date rendered with dot separators, e.g. "2024.03.31".
    static func dottedDate(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%04d.%02d.%02d", c.year, c.month, c.day)
    }

    static func dottedMonthDay(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%02d.%02d", c.month, c.day)
    }

}
