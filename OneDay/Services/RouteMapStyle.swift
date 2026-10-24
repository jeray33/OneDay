import MapKit

nonisolated enum RouteMapStyle: String, CaseIterable, Identifiable {
    case muted, standard

    static let storageKey = "OneDay.routeMapStyle"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .muted
    }

    var label: String {
        switch self {
        case .muted: return "淡彩"
        case .standard: return "标准"
        }
    }

    var mapType: MKMapType {
        switch self {
        case .muted: return .mutedStandard
        case .standard: return .standard
        }
    }
}
