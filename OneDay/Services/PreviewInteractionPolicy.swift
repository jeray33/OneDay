import Foundation

/// Shared rules for system-edge exclusion and interruption-safe completions.
struct PreviewInteractionPolicy {
    private(set) var generation: UInt = 0

    mutating func invalidate() {
        generation &+= 1
    }

    func canComplete(_ generation: UInt, isActive: Bool) -> Bool {
        isActive && generation == self.generation
    }

    static func allowsStart(y: CGFloat, height: CGFloat,
                            topInset: CGFloat, bottomInset: CGFloat) -> Bool {
        let top = max(24, topInset + 8)
        let bottom = max(24, bottomInset + 8)
        return y > top && y < height - bottom
    }

    enum EndAction: Equatable {
        case browse, restore, stage, close
    }

    static func endAction(translation: CGSize, predicted: CGSize,
                          verticalLocked: Bool, canDelete: Bool,
                          cancelled: Bool = false) -> EndAction {
        guard !cancelled else { return .restore }
        guard verticalLocked else { return .browse }
        guard abs(translation.height) > abs(translation.width) else { return .restore }
        if translation.height < 0, !canDelete { return .restore }
        if translation.height < -180 || predicted.height < -460 { return .stage }
        if translation.height > 80 || predicted.height > 240 { return .close }
        return .restore
    }
}
