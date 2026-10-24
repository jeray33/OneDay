import Foundation
import CoreLocation

/// One grid photo and its scroll anchor, shared with preview restoration.
struct MagazineBlock: Identifiable {
    var id = UUID()
    var items: [PhotoItem]
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

    /// Uppercase English headline used on the photo page when the day stays in
    /// one place.
    var englishTitle: String {
        switch self {
        case .dawn: return "DAWN"
        case .morning: return "MORNING"
        case .noon: return "NOON"
        case .afternoon: return "AFTERNOON"
        case .evening: return "EVENING"
        case .night: return "NIGHT"
        }
    }

    /// The band of `date`'s clock hour read in `timeZone` (the capture's
    /// local zone; see `CaptureClock`).
    static func band(for date: Date?, in timeZone: TimeZone = .current) -> TimeBand {
        guard let date else { return .noon }
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let h = calendar.component(.hour, from: date)
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
    var id = UUID()
    let band: TimeBand
    let timeText: String
    var placeName: String?
    /// Identifies the route stop this section belongs to, so headings can
    /// update in place after reverse geocoding lands. Nil in time-only mode.
    var placeStopID: String? = nil
    let anchorLocation: CLLocation?
    var blocks: [MagazineBlock]
    var placeHeading: String? = nil
    /// True while the stop exists but its title has not resolved yet; the
    /// heading reserves its height and fades in when the title lands.
    var placeHeadingPending = false
    var showsTimeHeading = true
    var timeHeadingIsNested = false
    var placeCard: PlaceSectionCard? = nil

    var title: String { band.title }

    /// Photo order for detecting name-only updates independently of titles.
    var structure: [String] {
        blocks.map { block in
            block.items.map(\.id).joined(separator: ",")
        }
    }
}
