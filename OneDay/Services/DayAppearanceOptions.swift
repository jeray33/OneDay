import Foundation

nonisolated enum SectionTitleSize: String, CaseIterable, Identifiable {
    case xsmall, small, medium, large, xlarge

    var id: String { rawValue }
    var label: String { "\(Int(size)) pt" }

    var size: CGFloat {
        switch self {
        case .xsmall: return 14
        case .small: return 20
        case .medium: return 26
        case .large: return 32
        case .xlarge: return 38
        }
    }
}

nonisolated enum PhotoShadowLevel: String, CaseIterable, Identifiable {
    case none, extraFine, fine, small, medium, mediumLarge, large, max

    var id: Self { self }
    var label: String { "\(Int((scale * 100).rounded()))%" }

    /// Scales opacity, blur and offset together, not a single point dimension.
    var scale: CGFloat {
        switch self {
        case .none:        return 0
        case .extraFine:   return 0.15
        case .fine:        return 0.28
        case .small:       return 0.42
        case .medium:      return 0.58
        case .mediumLarge: return 0.72
        case .large:       return 0.86
        case .max:         return 1
        }
    }
}

nonisolated enum PhotoBorderWidth: String, CaseIterable, Identifiable {
    case none, thin, medium, thick, max

    var id: String { rawValue }
    var label: String { "\(Int((scale * 100).rounded()))%" }

    /// Scales each layout's base border, which varies with column count.
    var scale: CGFloat {
        switch self {
        case .none:   return 0
        case .thin:   return 0.33
        case .medium: return 0.56
        case .thick:  return 0.78
        case .max:    return 1
        }
    }
}

nonisolated enum PhotoCornerRadius: String, CaseIterable, Identifiable {
    case none, slight, small, medium, large, xlarge

    var id: String { rawValue }
    var label: String { "\(Int(value)) pt" }

    var value: CGFloat {
        switch self {
        case .none:   return 0
        case .slight: return 4
        case .small:  return 8
        case .medium: return 14
        case .large:  return 22
        case .xlarge: return 32
        }
    }
}
