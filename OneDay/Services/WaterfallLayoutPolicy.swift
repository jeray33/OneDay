import Foundation
import CoreGraphics

nonisolated enum DayGridArrangement: String, CaseIterable, Identifiable {
    case aligned, waterfall

    static let storageKey = "OneDay.gridArrangement"
    var id: Self { self }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .aligned
    }

    var label: String {
        switch self {
        case .aligned: return "对齐网格"
        case .waterfall: return "瀑布流"
        }
    }
}

/// Position planning only. Heights come from the actual SwiftUI cells, including
/// captions, so loading or unloading an image never changes the layout.
nonisolated enum WaterfallLayoutPolicy {
    struct Plan: Equatable {
        let frames: [CGRect]
        let size: CGSize
    }

    static func plan(
        heights: [CGFloat],
        columnCount: Int,
        columnWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> Plan {
        let count = min(max(columnCount, 1), 6)
        let width = finiteNonnegative(columnWidth)
        let horizontal = finiteNonnegative(horizontalSpacing)
        let vertical = finiteNonnegative(verticalSpacing)
        var bottoms = Array(repeating: CGFloat.zero, count: count)
        var occupied = Array(repeating: false, count: count)
        var frames: [CGRect] = []
        frames.reserveCapacity(heights.count)

        for height in heights {
            // Empty columns win ties, then the leftmost shortest column.
            let column = (0..<count).min {
                let lhs = bottoms[$0] + (occupied[$0] ? vertical : 0)
                let rhs = bottoms[$1] + (occupied[$1] ? vertical : 0)
                if lhs == rhs, occupied[$0] != occupied[$1] {
                    return !occupied[$0]
                }
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }!
            let y = bottoms[column] + (occupied[column] ? vertical : 0)
            let frame = CGRect(
                x: CGFloat(column) * (width + horizontal),
                y: y, width: width, height: finiteNonnegative(height)
            )
            frames.append(frame)
            bottoms[column] = frame.maxY
            occupied[column] = true
        }

        return Plan(
            frames: frames,
            size: CGSize(
                width: CGFloat(count) * width + CGFloat(count - 1) * horizontal,
                height: bottoms.max() ?? 0
            )
        )
    }

    static func shouldLoadImage(frame: CGRect, viewport: CGRect) -> Bool {
        guard !frame.isEmpty, !viewport.isEmpty else { return false }
        // One screen of prefetch on either side, without retaining the whole day.
        return frame.intersects(viewport.insetBy(dx: 0, dy: -viewport.height))
    }

    struct Anchor: Equatable {
        let id: String
        let minY: CGFloat
    }

    static func anchor(frames: [String: CGRect], viewport: CGRect) -> Anchor? {
        let visible = frames.filter { $0.value.intersects(viewport) }
        // Prefer a complete card's top edge over a mostly scrolled-away card.
        let completeTops = visible.filter { $0.value.minY >= viewport.minY }
        let candidates = completeTops.isEmpty ? visible : completeTops
        let first = candidates.min {
            if $0.value.minY != $1.value.minY { return $0.value.minY < $1.value.minY }
            if $0.value.minX != $1.value.minX { return $0.value.minX < $1.value.minX }
            return $0.key < $1.key
        }
        return first.map { Anchor(id: $0.key, minY: $0.value.minY) }
    }

    static func restoredOffset(
        anchor: Anchor, frames: [String: CGRect], currentOffset: CGFloat
    ) -> CGFloat? {
        guard let frame = frames[anchor.id] else { return nil }
        let offset = currentOffset + frame.minY - anchor.minY
        return offset.isFinite ? offset : nil
    }

    private static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }
}
