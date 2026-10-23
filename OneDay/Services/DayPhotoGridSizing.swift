import Foundation
import CoreGraphics

nonisolated enum DayPhotoSideSpacing: String, CaseIterable, Identifiable {
    case none, small, medium, large, max

    static let storageKey = "OneDay.photoSideSpacing"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .max
    }

    var fraction: CGFloat {
        switch self {
        case .none: return 0
        case .small: return 0.25
        case .medium: return 0.5
        case .large: return 0.75
        case .max: return 1
        }
    }
}

/// Shared by the aligned and waterfall layouts. The maximum reproduces the
/// original 20pt section inset, inner padding and single-column narrowing.
nonisolated struct DayPhotoGridSizing {
    let columnCount: Int
    let cellWidth: CGFloat
    let horizontalSpacing: CGFloat
    let sideInset: CGFloat

    var sideInsetLabel: String {
        "\(Double(sideInset).formatted(.number.precision(.fractionLength(0...1)))) pt"
    }

    init(
        viewportWidth: CGFloat, columnCount: Int,
        horizontalSpacing: CGFloat?, sideSpacing: DayPhotoSideSpacing
    ) {
        let width = viewportWidth.isFinite ? Swift.max(viewportWidth, 1) : 1
        let count = min(Swift.max(columnCount, 1), 6)
        let automaticSpacing: CGFloat = count <= 3 ? 16 : count == 4 ? 14 : 12
        let requestedSpacing = horizontalSpacing ?? automaticSpacing
        let spacing = requestedSpacing.isFinite ? Swift.max(requestedSpacing, 0) : automaticSpacing
        let legacyContentWidth = width - 40
        let legacyInnerInset: CGFloat = legacyContentWidth >= 560 ? 20 : 8
        let legacyAvailableWidth = Swift.max(legacyContentWidth - legacyInnerInset * 2, 1)
        let legacyCellWidth = Swift.max(
            (legacyAvailableWidth - spacing * CGFloat(count - 1)) / CGFloat(count), 1
        )
        let maximumInset = count == 1
            ? Swift.max((width - legacyCellWidth * 0.78) / 2, 0)
            : 20 + legacyInnerInset
        let inset = maximumInset * sideSpacing.fraction

        self.columnCount = count
        self.horizontalSpacing = spacing
        self.sideInset = inset
        self.cellWidth = Swift.max(
            (width - inset * 2 - spacing * CGFloat(count - 1)) / CGFloat(count), 1
        )
    }
}
