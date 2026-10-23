import Foundation

/// The supported page backgrounds. Keep the former bright2 storage value so
/// existing pastel selections retain their appearance after the rename.
nonisolated enum PageBackground: String, CaseIterable, Identifiable {
    case paper, pureWhite
    case bright = "bright2"

    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .paper
    }

    var label: String {
        switch self {
        case .paper: return "白色"
        case .pureWhite: return "纯白色"
        case .bright: return "明快"
        }
    }

    var icon: String {
        switch self {
        case .paper: return "sun.max"
        case .pureWhite: return "circle"
        case .bright: return "sun.haze.fill"
        }
    }
}

nonisolated enum DayAppearancePreferences {
    static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        let key = "OneDay.pageBackground"
        let background = PageBackground(savedValue: defaults.string(forKey: key))
        defaults.set(background.rawValue, forKey: key)
        for obsoleteKey in [
            "OneDay.coverBackgroundMode", "OneDay.coverMode",
            "OneDay.photoLayoutMode", "OneDay.enabledTemplates",
            "OneDay.borderStyle", "OneDay.sharedContributorMatch",
            "OneDay.scrollStagger"
        ] {
            defaults.removeObject(forKey: obsoleteKey)
        }
    }
}
