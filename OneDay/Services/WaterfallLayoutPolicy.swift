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

/// Position and visibility planning, independent of instantiated SwiftUI cells.
nonisolated enum WaterfallLayoutPolicy {
    struct Plan: Equatable {
        let frames: [CGRect]
        let size: CGSize
    }

    struct CellMetrics: Equatable {
        let cardHeight: CGFloat
        let captionHeight: CGFloat?
        var height: CGFloat { cardHeight + (captionHeight.map { $0 + 6 } ?? 0) }
    }

    static func photoMetrics(
        width: CGFloat, aspectRatio: CGFloat, border: CGFloat, captionHeight: CGFloat?
    ) -> CellMetrics {
        let ratio = min(max(aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1, 9 / 20), 16 / 9)
        let border = finiteNonnegative(border)
        let imageWidth = max(finiteNonnegative(width) - border * 2, 1)
        return CellMetrics(
            cardHeight: (imageWidth / ratio).rounded() + border * 2,
            captionHeight: captionHeight.map(finiteNonnegative).flatMap { $0 > 0 ? $0 : nil })
    }

    /// Quantized overscan keeps the whole viewport covered while avoiding a
    /// SwiftUI update on every scroll frame.
    static func renderWindow(for viewport: CGRect) -> CGRect {
        guard !viewport.isEmpty, viewport.minY.isFinite, viewport.height.isFinite else { return .zero }
        let step = max(1, viewport.height / 2)
        let top = floor(viewport.minY / step) * step - viewport.height
        return CGRect(x: viewport.minX, y: top, width: viewport.width, height: viewport.height * 3.5)
    }

    static func shouldReplaceRenderWindow(_ current: CGRect, with next: CGRect) -> Bool {
        guard current != next else { return false }
        guard !current.isEmpty, !next.isEmpty,
              current.size == next.size, current.minX == next.minX else { return true }
        // Retain one quantization step in either direction. At least half a
        // screen of overscan remains, without churning cells at a boundary.
        return abs(next.minY - current.minY) > max(1, next.height / 7) * 1.01
    }

    /// Frames in each column do not overlap and have monotonic bottoms.
    /// Querying them costs O(columns × log(N) + visible), not an N-cell scan.
    struct VisibilityIndex {
        private let frames: [CGRect]
        private let columns: [[Int]]

        init(frames: [CGRect]) {
            self.frames = frames
            let grouped = Dictionary(grouping: frames.indices, by: { frames[$0].minX })
            columns = grouped.keys.sorted().map { x in
                grouped[x]!.sorted {
                    frames[$0].minY == frames[$1].minY
                        ? $0 < $1 : frames[$0].minY < frames[$1].minY
                }
            }
        }

        func indices(in viewport: CGRect, pinned: Set<Int> = []) -> [Int] {
            var result = Set(pinned.filter { frames.indices.contains($0) })
            if !viewport.isEmpty, viewport.minY.isFinite, viewport.maxY.isFinite {
                for column in columns {
                    var low = 0
                    var high = column.count
                    while low < high {
                        let middle = (low + high) / 2
                        if frames[column[middle]].maxY <= viewport.minY { low = middle + 1 }
                        else { high = middle }
                    }
                    for position in low..<column.count {
                        let index = column[position]
                        if frames[index].minY >= viewport.maxY { break }
                        if frames[index].intersects(viewport) { result.insert(index) }
                    }
                }
            }
            return result.sorted()
        }
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

    /// How many viewport heights a loaded cell may drift away before its
    /// image is released. Larger retains more images; smaller re-requests
    /// more often.
    static let unloadScreens: CGFloat = 2.5

    /// Image-existence gating with hysteresis: an unloaded cell requests its
    /// image within one screen of the viewport; a loaded cell keeps it until
    /// it drifts past `unloadScreens` screens.
    static func shouldLoadImage(frame: CGRect, viewport: CGRect, isLoaded: Bool = false) -> Bool {
        guard !frame.isEmpty, !viewport.isEmpty else { return false }
        let reach = viewport.height * (isLoaded ? unloadScreens : 1)
        return frame.intersects(viewport.insetBy(dx: 0, dy: -reach))
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
