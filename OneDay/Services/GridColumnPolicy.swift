import Foundation

/// Keeps automatic columns day-specific and manual columns shared across days.
nonisolated struct GridColumnPolicy {
    enum Mode: String {
        case automatic, manual
    }

    static let modeKey = "OneDay.gridColumnMode"
    static let countKey = "OneDay.gridColumnCount"

    var mode: Mode
    var manualCount: Int
    let automaticCount: Int

    init(itemCount: Int, defaults: UserDefaults = .standard) {
        automaticCount = itemCount < 20 ? 1 : itemCount <= 50 ? 2 : 3
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .automatic
        let saved = defaults.integer(forKey: Self.countKey)
        manualCount = (1...6).contains(saved) ? saved : automaticCount
    }

    var columnCount: Int {
        mode == .automatic ? automaticCount : manualCount
    }

    mutating func selectManual(_ count: Int) {
        manualCount = min(max(count, 1), 6)
        mode = .manual
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(manualCount, forKey: Self.countKey)
    }
}
