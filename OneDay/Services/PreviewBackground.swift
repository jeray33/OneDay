nonisolated enum PreviewBackground: String, CaseIterable, Identifiable {
    case day, immersive

    static let storageKey = "OneDay.previewBackground"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .day
    }

    var label: String {
        switch self {
        case .day: return "跟随当天页"
        case .immersive: return "沉浸深色"
        }
    }
}
