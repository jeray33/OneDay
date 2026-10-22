import CoreGraphics

/// Pure geometry math for the day page bottom scrubber.
///
/// All values live in the scroll view's own spaces and the code never
/// assumes a sign convention for `ScrollGeometry.contentOffset` relative to
/// content insets: `offset` is whatever the scroll view reports, and every
/// target is derived from differences against the currently observed
/// offset, so reading and writing stay paired in the same space.
nonisolated struct DayScrubberMetrics: Equatable {
    /// Content offset as reported by the scroll view at the last update.
    var offset: CGFloat
    /// How far the content top has travelled below its top-rest position:
    /// 0 at top rest, `scrollableDistance` at bottom rest.
    var scrolledDistance: CGFloat
    /// Total scrollable distance: content height minus the visible window.
    var scrollableDistance: CGFloat

    /// Below this a page is considered non-scrollable and the scrubber
    /// disables itself.
    static let minimumScrollableDistance: CGFloat = 16

    init(offset: CGFloat = 0, scrolledDistance: CGFloat = 0, scrollableDistance: CGFloat = 0) {
        self.offset = offset
        self.scrolledDistance = scrolledDistance
        self.scrollableDistance = max(0, scrollableDistance)
    }

    var isScrollable: Bool { scrollableDistance > Self.minimumScrollableDistance }

    /// Progress 0…1 for an arbitrary scrolled distance, edge-clamped.
    func progress(forScrolledDistance distance: CGFloat) -> CGFloat {
        guard scrollableDistance > 0 else { return 0 }
        return min(max(distance / scrollableDistance, 0), 1)
    }

    var progress: CGFloat { progress(forScrolledDistance: scrolledDistance) }

    /// Scrolled distance for a scrubber progress, edge-clamped.
    func scrolledDistance(forProgress progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1) * scrollableDistance
    }

    /// Content offset that lands the given progress, expressed as a delta
    /// from the offset observed at the last update.
    func targetOffset(forProgress progress: CGFloat) -> CGFloat {
        offset + (scrolledDistance(forProgress: progress) - scrolledDistance)
    }
}

/// Tick-mapping and haptic-crossing rules for the scrubber track.
nonisolated enum DayScrubberPolicy {
    /// Scrub progress for a touch x on a track of the given width, keeping
    /// `inset` points at each end unusable so ticks stay clear of the
    /// capsule's curved ends.
    static func progress(forLocationX x: CGFloat, width: CGFloat, inset: CGFloat) -> CGFloat {
        let usable = width - inset * 2
        guard usable > 0 else { return 0 }
        return min(max((x - inset) / usable, 0), 1)
    }

    /// Track fractions of the long section marks, one per section start.
    ///
    /// Distances are section-top positions measured below the content top.
    /// Marks too close to the very top or beyond the reachable bottom are
    /// dropped, and neighbours closer than `mergeSpacing` collapse into one
    /// so the track never turns into a wall of long lines.
    static func markFractions(sectionDistances: [CGFloat],
                              scrollableDistance: CGFloat,
                              edgeMargin: CGFloat = 48,
                              mergeSpacing: CGFloat = 48) -> [CGFloat] {
        guard scrollableDistance > 0 else { return [] }
        let sorted = sectionDistances
            .filter { $0 > edgeMargin && $0 < scrollableDistance - edgeMargin / 2 }
            .sorted()
        var merged: [CGFloat] = []
        for distance in sorted {
            if let last = merged.last, distance - last < mergeSpacing { continue }
            merged.append(distance)
        }
        return merged.map { min(max($0 / scrollableDistance, 0), 1) }
    }

    /// Places each section start on its nearest interior tick so section
    /// marks are ordinary, evenly spaced ticks drawn taller. Sections that
    /// land on an already used tick keep the earlier one.
    static func snappedMarks(fractions: [CGFloat], tickCount: Int) -> [DayScrubberMark] {
        guard tickCount > 2 else { return [] }
        let segments = CGFloat(tickCount - 1)
        var result: [DayScrubberMark] = []
        for fraction in fractions.sorted() {
            let tick = min(max(Int((fraction * segments).rounded()), 1), tickCount - 2)
            if result.last?.tick == tick { continue }
            result.append(DayScrubberMark(tick: tick, fraction: fraction))
        }
        return result
    }

    /// Magnetic detent around section ticks, with hysteresis: a finger
    /// within `enterRadius` of a mark is caught by the nearest one, and an
    /// already caught mark holds until the finger is beyond `exitRadius`.
    /// Returns the caught index into `markXs`, or nil when free.
    static func detentIndex(locationX x: CGFloat,
                            markXs: [CGFloat],
                            current: Int?,
                            enterRadius: CGFloat,
                            exitRadius: CGFloat) -> Int? {
        if let current, markXs.indices.contains(current),
           abs(x - markXs[current]) <= exitRadius {
            return current
        }
        var best: Int?
        var bestDistance = enterRadius
        for (index, markX) in markXs.enumerated() {
            let distance = abs(x - markX)
            if distance <= bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// Which haptic boundaries a scrub move crossed, if any. Ticks sit at
    /// `i / (tickCount - 1)`; only interior ticks count, and a boundary must
    /// be strictly between the old and new progress (landing exactly on a
    /// tick does not count as crossing it).
    static func crossings(from oldProgress: CGFloat,
                          to newProgress: CGFloat,
                          tickCount: Int,
                          marks: [CGFloat]) -> DayScrubberCrossings {
        guard oldProgress != newProgress else { return DayScrubberCrossings() }
        let low = min(oldProgress, newProgress)
        let high = max(oldProgress, newProgress)

        var tickCrossings = 0
        if tickCount > 2 {
            let segments = tickCount - 1
            let first = max(1, Int(floor(low * CGFloat(segments))) + 1)
            let last = min(segments - 1, Int(ceil(high * CGFloat(segments))) - 1)
            if last >= first { tickCrossings = last - first + 1 }
        }
        let crossesSectionMark = marks.contains { $0 > low && $0 < high }
        return DayScrubberCrossings(tickCrossings: tickCrossings,
                                    crossesSectionMark: crossesSectionMark)
    }
}

/// A section start placed on the tick grid. `fraction` keeps the exact
/// section position so scrolling to it lands on the section's first row.
nonisolated struct DayScrubberMark: Equatable {
    var tick: Int
    var fraction: CGFloat
}

/// Haptic-relevant events of a single scrub move.
nonisolated struct DayScrubberCrossings: Equatable {
    var tickCrossings: Int = 0
    var crossesSectionMark: Bool = false
}
