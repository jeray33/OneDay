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

enum PhotoShadowLevel: String, CaseIterable, Identifiable {
    case none, extraFine, fine, small, medium, mediumLarge, large, max

    var id: Self { self }

    var label: String {
        switch self {
        case .none:        return "无投影"
        case .extraFine:   return "极细"
        case .fine:        return "细小"
        case .small:       return "较小"
        case .medium:      return "中等"
        case .mediumLarge: return "稍大"
        case .large:       return "较大"
        case .max:         return "最大"
        }
    }

    /// Multiplier for every photo-shadow component. Max preserves the current effect.
    var scale: CGFloat {
        switch self {
        case .none:        return 0
        case .extraFine:   return 0.15
        case .fine:        return 0.28
        case .small:       return 0.42
        case .medium:      return 0.58
        case .mediumLarge: return 0.72
        case .large:       return 0.86
        case .max:         return 1
        }
    }
}

enum PhotoBorderWidth: String, CaseIterable, Identifiable {
    case none, thin, medium, thick, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return "无"
        case .thin:   return "细"
        case .medium: return "中"
        case .thick:  return "厚"
        case .max:    return "最厚"
        }
    }
    /// Multiplier applied to every template's base border value.
    var scale: CGFloat {
        switch self {
        case .none:   return 0
        case .thin:   return 0.33
        case .medium: return 0.56
        case .thick:  return 0.78
        case .max:    return 1.0
        }
    }
}

enum PhotoBorderStyle: String, CaseIterable, Identifiable {
    case white    = "white"
    case black    = "black"
    case colored  = "colored"
    case polaroid = "polaroid"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .white:    return "白边"
        case .black:    return "黑边"
        case .colored:  return "彩边"
        case .polaroid: return "拍立得"
        }
    }
    var icon: String {
        switch self {
        case .white:    return "rectangle.portrait"
        case .black:    return "rectangle.portrait.fill"
        case .colored:  return "paintpalette"
        case .polaroid: return "rectangle.portrait.bottomhalf.filled"
        }
    }
    /// Whether this style uses the tall bottom edge (Polaroid look).
    var isPolaroid: Bool { self == .polaroid }
}

enum PageBackground: String, CaseIterable, Identifiable {
    case paper, dark, warm, dominant, vibrant, bright, bright2
    var id: Self { self }

    var label: String {
        switch self {
        case .paper:    return "白色"
        case .dark:     return "黑色"
        case .warm:     return "暖橙"
        case .dominant: return "照片主色"
        case .vibrant:  return "主色·艳丽"
        case .bright:   return "明快1"
        case .bright2:  return "明快2"
        }
    }

    var icon: String {
        switch self {
        case .paper:    return "sun.max"
        case .dark:     return "moon"
        case .warm:     return "circle.righthalf.filled"
        case .dominant: return "paintpalette"
        case .vibrant:  return "paintpalette.fill"
        case .bright:   return "sun.max.fill"
        case .bright2:  return "sun.haze.fill"
        }
    }
}

// MARK: - Scroll transition animation config

/// How much photos scale when entering/leaving the viewport.
/// Bottom photos: 1 + value; Top photos: 1 - value.
enum ScrollScaleMagnitude: String, CaseIterable, Identifiable {
    case none, subtle, medium, strong, bold, extreme
    var id: String { rawValue }
    var value: CGFloat {
        switch self {
        case .none:    return 0
        case .subtle:  return 0.08
        case .medium:  return 0.14
        case .strong:  return 0.20
        case .bold:    return 0.28
        case .extreme: return 0.38
        }
    }
    var label: String {
        switch self {
        case .none:    return "无"
        case .subtle:  return "±0.08"
        case .medium:  return "±0.14"
        case .strong:  return "±0.20"
        case .bold:    return "±0.28"
        case .extreme: return "±0.38"
        }
    }
}

/// Vertical offset (pt) applied when a photo is off-screen.
enum ScrollMovement: String, CaseIterable, Identifiable {
    case none, small, medium, large, xlarge, huge
    var id: String { rawValue }
    var value: CGFloat {
        switch self {
        case .none:   return 0
        case .small:  return 30
        case .medium: return 60
        case .large:  return 100
        case .xlarge: return 160
        case .huge:   return 250
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .small:  return "30 pt"
        case .medium: return "60 pt"
        case .large:  return "100 pt"
        case .xlarge: return "160 pt"
        case .huge:   return "250 pt"
        }
    }
}

/// Rotation angle (degrees) when a photo is off-screen.
enum ScrollRotation: String, CaseIterable, Identifiable {
    case none, slight, medium, strong, bold
    var id: String { rawValue }
    var value: Double {
        switch self {
        case .none:   return 0
        case .slight: return 3
        case .medium: return 8
        case .strong: return 14
        case .bold:   return 22
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .slight: return "3°"
        case .medium: return "8°"
        case .strong: return "14°"
        case .bold:   return "22°"
        }
    }
}

/// Opacity of off-screen photos (0 = invisible, 1 = fully visible).
enum ScrollFade: String, CaseIterable, Identifiable {
    case hidden, faint, half, visible
    var id: String { rawValue }
    var offScreenOpacity: Double {
        switch self {
        case .hidden:  return 0
        case .faint:   return 0.15
        case .half:    return 0.40
        case .visible: return 1.0
        }
    }
    var label: String {
        switch self {
        case .hidden:  return "全透明"
        case .faint:   return "微透 0.15"
        case .half:    return "半透 0.40"
        case .visible: return "不透明"
        }
    }
}

/// X-axis (horizontal axis) tilt: top/bottom perspective depth effect.
enum ScrollTiltX: String, CaseIterable, Identifiable {
    case none, subtle, light, medium, strong, bold
    var id: String { rawValue }
    var degrees: Double {
        switch self {
        case .none:   return 0
        case .subtle: return 4
        case .light:  return 8
        case .medium: return 15
        case .strong: return 25
        case .bold:   return 40
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .subtle: return "4°"
        case .light:  return "8°"
        case .medium: return "15°"
        case .strong: return "25°"
        case .bold:   return "40°"
        }
    }
}

/// Y-axis (vertical axis) tilt: left/right perspective depth effect.
enum ScrollTiltY: String, CaseIterable, Identifiable {
    case none, subtle, light, medium, strong, bold
    var id: String { rawValue }
    var degrees: Double {
        switch self {
        case .none:   return 0
        case .subtle: return 4
        case .light:  return 8
        case .medium: return 15
        case .strong: return 25
        case .bold:   return 40
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .subtle: return "4°"
        case .light:  return "8°"
        case .medium: return "15°"
        case .strong: return "25°"
        case .bold:   return "40°"
        }
    }
}

/// How quickly the tilt angle decreases from the extremes toward the viewport center.
/// Low power = high angle maintained across most positions;
/// High power = angle concentrated only at extremes, near-flat near center.
enum ScrollTiltDecay: String, CaseIterable, Identifiable {
    case even, mild, linear, fast, edge
    var id: String { rawValue }
    var power: Double {
        switch self {
        case .even:   return 0.35   // angle sustained across full range
        case .mild:   return 0.65
        case .linear: return 1.00   // proportional to position
        case .fast:   return 1.80
        case .edge:   return 3.00   // angle only near viewport edges
        }
    }
    var label: String {
        switch self {
        case .even:   return "均匀"
        case .mild:   return "渐减"
        case .linear: return "线性"
        case .fast:   return "急减"
        case .edge:   return "端点"
        }
    }
}

/// Blur radius applied to photos as they enter from below (0 = sharp, fades to clear at identity).
enum ScrollBlur: String, CaseIterable, Identifiable {
    case none, light, medium, strong, heavy
    var id: String { rawValue }
    var radius: Double {
        switch self {
        case .none:   return 0
        case .light:  return 3
        case .medium: return 6
        case .strong: return 12
        case .heavy:  return 20
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .light:  return "3"
        case .medium: return "6"
        case .strong: return "12"
        case .heavy:  return "20"
        }
    }
}

/// Parallax lag applied to blocks scrolling upward: higher factor = slower apparent exit speed.
enum ScrollParallax: String, CaseIterable, Identifiable {
    case none, slight, medium, strong
    var id: String { rawValue }
    /// Extra downward offset (pts) per unit of topLeading phase to slow apparent upward movement.
    var factor: CGFloat {
        switch self {
        case .none:   return 0
        case .slight: return 30
        case .medium: return 70
        case .strong: return 130
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .slight: return "细微"
        case .medium: return "适中"
        case .strong: return "明显"
        }
    }
}

/// Phase-shift offset applied per photo index within multi-photo blocks to create a cascade.
enum ScrollStagger: String, CaseIterable, Identifiable {
    case none, slight, medium, strong, bold
    var id: String { rawValue }
    /// Added to phase.value for each additional photo in the block.
    var factor: Double {
        switch self {
        case .none:   return 0
        case .slight: return 0.25
        case .medium: return 0.50
        case .strong: return 0.80
        case .bold:   return 1.20
        }
    }
    var label: String {
        switch self {
        case .none:   return "无"
        case .slight: return "细微"
        case .medium: return "适中"
        case .strong: return "明显"
        case .bold:   return "强烈"
        }
    }
}

/// Spring curve for the scroll transition animation.
enum ScrollSpring: String, CaseIterable, Identifiable {
    case snappy, standard, bouncy, slow
    var id: String { rawValue }
    var animation: Animation {
        switch self {
        case .snappy:   return .spring(response: 0.32, dampingFraction: 0.90)
        case .standard: return .spring(response: 0.55, dampingFraction: 0.82)
        case .bouncy:   return .spring(response: 0.60, dampingFraction: 0.65)
        case .slow:     return .spring(response: 0.95, dampingFraction: 0.88)
        }
    }
    var label: String {
        switch self {
        case .snappy:   return "急促"
        case .standard: return "标准"
        case .bouncy:   return "弹性"
        case .slow:     return "缓慢"
        }
    }
}

/// Time-travel mode shown after tapping "时光穿梭" on the home screen.
enum RewindMode: String, CaseIterable, Identifiable {
    case flash, rewind
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flash:  return "经典闪现"
        case .rewind: return "时光倒流"
        }
    }
    var icon: String {
        switch self {
        case .flash:  return "photo.stack"
        case .rewind: return "clock.arrow.circlepath"
        }
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

/// Control style for the tunnel rewind mode.
enum TunnelControl: String, CaseIterable, Identifiable {
    case auto, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:   return "自动穿梭"
        case .manual: return "手动滑动"
        }
    }
    var icon: String {
        switch self {
        case .auto:   return "play.circle"
        case .manual: return "hand.draw"
        }
    }
}

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

/// Strength of the perspective speed difference between near and far photos.
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

/// Three-layer page flip transition style for the cover/content/back stack.
enum PageFlipMode: String, CaseIterable, Identifiable {
    /// C: drag follows finger, snap-to-page on release, lower layer scales/fades in from a fixed start.
    case snapParallax = "snap"
    /// B: fully continuous drag, lower layer tracks finger linearly (more physical, harder to tune).
    case freePhysics = "free"
    /// Rigid physical paging with the departed page resting above-left at a slight angle.
    case staggeredPhysics = "staggered"
    /// Staggered physics with same-gesture handoff between content scrolling and page flipping.
    case continuousStaggered = "continuousStaggered"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .snapParallax: return "层叠吸附"
        case .freePhysics:  return "全跟手物理"
        case .staggeredPhysics: return "错落物理"
        case .continuousStaggered: return "连续错落"
        }
    }
    var icon: String {
        switch self {
        case .snapParallax: return "rectangle.stack"
        case .freePhysics:  return "rectangle.stack.fill"
        case .staggeredPhysics: return "square.2.layers.3d"
        case .continuousStaggered: return "arrow.up.and.down"
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

    static func weekday(_ date: Date) -> String {
        let w = Calendar.current.component(.weekday, from: date)
        return weekdaySymbols[(w - 1) % 7]
    }

    static func components(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Cover top caption, e.g. "2 年前的一天".
    static func coverCaption(_ date: Date) -> String? {
        guard let rel = relativeCaption(date) else { return "今天的一天" }
        return "\(rel)的一天"
    }

    /// Big date rendered with dot separators, e.g. "2024.03.31".
    static func dottedDate(_ date: Date) -> String {
        let c = components(date)
        return String(format: "%04d.%02d.%02d", c.year, c.month, c.day)
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

    /// A longer, editorial caption for the back cover: combines relative distance
    /// with weekday for a "this very day" feel.
    static func backCoverCaption(_ date: Date) -> String {
        let wd = weekday(date)
        if let rel = relativeCaption(date) {
            return "那个 \(rel) 的\(wd)"
        }
        return "那个\(wd)"
    }
}
