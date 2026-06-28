import Foundation
import CoreLocation

enum BlockTemplate: String, CaseIterable, Hashable {
    case single    // reduced-width single, alternating alignment
    case duo       // two side by side, equal-height row
    case trio      // three across, equal-height row
    case collage   // big+small group, height-locked columns
    case stack     // similar / burst deck
    case quote     // editorial pull-quote card (no photo)

    /// Whether this template appears in the user-facing layout picker.
    var isSelectable: Bool { self != .quote }

    var label: String {
        switch self {
        case .single:  return "单张"
        case .duo:     return "双张"
        case .trio:    return "三联"
        case .collage: return "拼贴"
        case .stack:   return "叠牌"
        case .quote:   return "引言"
        }
    }
}

/// Controls block sizing; derived from total photo count so denser days feel tighter.
struct LayoutConfig: Equatable {
    /// Fraction of contentWidth for a single photo (< 1 gives breathing room).
    var singleScale: CGFloat
    /// Target image-area height (pt) for duo / trio equal-height rows.
    var rowHeight: CGFloat
    /// 0 = no border, 1 = current max. Applied uniformly to every template's base border.
    var borderScale: CGFloat = 1.0
    /// White frame or photo-tinted colored frame.
    var borderStyle: PhotoBorderStyle = .white
    /// Phase-value offset per photo index in multi-photo blocks (0 = no stagger).
    var staggerFactor: Double = 0

    static func make(itemCount: Int) -> LayoutConfig {
        switch itemCount {
        case ..<6:   return LayoutConfig(singleScale: 0.82, rowHeight: 200)
        case ..<16:  return LayoutConfig(singleScale: 0.78, rowHeight: 180)
        case ..<31:  return LayoutConfig(singleScale: 0.72, rowHeight: 160)
        default:     return LayoutConfig(singleScale: 0.68, rowHeight: 145)
        }
    }
}

struct MagazineBlock: Identifiable {
    let id = UUID()
    let template: BlockTemplate
    var items: [PhotoItem]
    var caption: String? = nil
}

enum TimeBand: Int, CaseIterable {
    case dawn, morning, noon, afternoon, evening, night

    var title: String {
        switch self {
        case .dawn: return "凌晨"
        case .morning: return "上午"
        case .noon: return "午间"
        case .afternoon: return "午后"
        case .evening: return "傍晚"
        case .night: return "夜晚"
        }
    }

    static func band(for date: Date?) -> TimeBand {
        guard let date else { return .noon }
        let h = Calendar.current.component(.hour, from: date)
        switch h {
        case 0..<5: return .dawn
        case 5..<11: return .morning
        case 11..<14: return .noon
        case 14..<18: return .afternoon
        case 18..<21: return .evening
        default: return .night
        }
    }
}

struct MagazineSection: Identifiable {
    let id = UUID()
    let band: TimeBand
    let timeText: String
    var placeName: String?
    let anchorLocation: CLLocation?
    var blocks: [MagazineBlock]

    var title: String { band.title }
}
