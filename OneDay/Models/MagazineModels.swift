import Foundation
import CoreLocation

enum BlockTemplate {
    case hero      // full-bleed single
    case single    // natural-aspect single
    case duo       // two side by side
    case trio      // three across, staggered
    case collage   // staggered same-location group
    case stack     // similar / burst deck
    case quote     // editorial pull-quote card (no photo)
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
