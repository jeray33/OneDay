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
    case white   = "white"
    case black   = "black"
    case colored = "colored"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .white:   return "白边"
        case .black:   return "黑边"
        case .colored: return "彩边"
        }
    }
    var icon: String {
        switch self {
        case .white:   return "rectangle.portrait"
        case .black:   return "rectangle.portrait.fill"
        case .colored: return "paintpalette"
        }
    }
}

enum PageBackground: String, CaseIterable, Identifiable {
    case paper, dark, warm, dominant, vibrant
    var id: Self { self }

    var label: String {
        switch self {
        case .paper:    return "白色"
        case .dark:     return "黑色"
        case .warm:     return "暖橙"
        case .dominant: return "照片主色"
        case .vibrant:  return "主色·艳丽"
        }
    }

    var icon: String {
        switch self {
        case .paper:    return "sun.max"
        case .dark:     return "moon"
        case .warm:     return "circle.righthalf.filled"
        case .dominant: return "paintpalette"
        case .vibrant:  return "paintpalette.fill"
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
