import Foundation

/// The supported page backgrounds. Keep the former bright2 storage value so
/// existing pastel selections retain their appearance after the rename.
nonisolated enum PageBackground: String, CaseIterable, Identifiable {
    case pureWhite, paper
    case bright = "bright2"

    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .paper
    }

    var label: String {
        switch self {
        case .paper: return "浅灰"
        case .pureWhite: return "白色"
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

nonisolated enum BackCoverBackground: String, CaseIterable, Identifiable {
    case paper, bright, immersive

    // Separate from the discarded multi-color back-cover preference.
    static let storageKey = "OneDay.backCoverAppearance"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .immersive
    }

    var label: String {
        switch self {
        case .paper: return "浅灰"
        case .bright: return "明快"
        case .immersive: return "沉静"
        }
    }

    /// Light backgrounds share the content page's exact color calculation.
    var pageBackground: PageBackground? {
        switch self {
        case .paper: return .paper
        case .bright: return .bright
        case .immersive: return nil
        }
    }
}

nonisolated enum DayAppearancePreferences {
    static func migrateLegacySettings(in defaults: UserDefaults = .standard) {
        let key = "OneDay.pageBackground"
        let background = PageBackground(savedValue: defaults.string(forKey: key))
        defaults.set(background.rawValue, forKey: key)
        for obsoleteKey in [
            "OneDay.coverStyle", "OneDay.backCoverBackground",
            "OneDay.backCoverTransition", "OneDay.backCoverReducedMotion",
            "OneDay.coverBackgroundMode", "OneDay.coverMode",
            "OneDay.photoLayoutMode", "OneDay.enabledTemplates",
            "OneDay.borderStyle", "OneDay.sharedContributorMatch",
            "OneDay.photoMap", "OneDay.mapBlendMode",
            "OneDay.bottomToolbar", "OneDay.dayScrollIndicator", "OneDay.textDayNavigation",
            "OneDay.scrollStagger", "OneDay.scrollScale",
            "OneDay.scrollMovement", "OneDay.scrollRotation",
            "OneDay.scrollFade", "OneDay.scrollSpring",
            "OneDay.scrollBlur", "OneDay.scrollParallax",
            "OneDay.scrollTiltX", "OneDay.scrollTiltY",
            "OneDay.scrollTiltDecay", "OneDay.rewindMode"
        ] {
            defaults.removeObject(forKey: obsoleteKey)
        }
    }
}
