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

/// Back cover background. The tinted option keeps the pastel derived from the
/// day's hero photo, immersive is a dark gradient in the hero photo's hue,
/// and the others are fixed neutrals.
nonisolated enum BackCoverBackground: String, CaseIterable, Identifiable {
    case tinted, white, gray, black, immersive

    static let storageKey = "OneDay.backCoverBackground"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .tinted
    }

    var label: String {
        switch self {
        case .tinted: return "彩色"
        case .white: return "白色"
        case .gray: return "灰色"
        case .black: return "黑色"
        case .immersive: return "沉浸"
        }
    }

    /// Nil keeps the photo-derived tint or gradient.
    var whiteLevel: Double? {
        switch self {
        case .tinted, .immersive: return nil
        case .white: return 1
        case .gray: return 0.86
        case .black: return 0
        }
    }

    var isDark: Bool { self == .black || self == .immersive }

    struct GradientStop: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
        var location: Double
    }

    /// Top-to-bottom stops of the immersive gradient: a deep tone of the hero
    /// photo's hue sinking to near black. Without a photo hue the stops are
    /// neutral graphite. Brightness stays low so light text keeps contrast.
    static func immersiveStops(hue: Double?, saturation: Double) -> [GradientStop] {
        guard let hue, hue.isFinite else {
            return [GradientStop(hue: 0, saturation: 0, brightness: 0.24, location: 0),
                    GradientStop(hue: 0, saturation: 0, brightness: 0.12, location: 0.5),
                    GradientStop(hue: 0, saturation: 0, brightness: 0.04, location: 1)]
        }
        let h = hue - hue.rounded(.down)
        let s = saturation.isFinite ? min(max(saturation, 0.35), 0.6) : 0.35
        return [GradientStop(hue: h, saturation: s, brightness: 0.32, location: 0),
                GradientStop(hue: h, saturation: s * 0.9, brightness: 0.15, location: 0.5),
                GradientStop(hue: h, saturation: s * 0.7, brightness: 0.05, location: 1)]
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
