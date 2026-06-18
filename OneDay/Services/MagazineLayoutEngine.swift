import Foundation
import CoreLocation

/// Turns a day's items into editorial magazine sections.
/// Heuristic clustering (burst / time / location); pluggable for future Vision similarity.
enum MagazineLayoutEngine {
    private static let burstGap: TimeInterval = 3
    private static let burstDistance: CLLocationDistance = 25
    private static let momentGap: TimeInterval = 20 * 60
    private static let momentDistance: CLLocationDistance = 300

    static func compose(_ items: [PhotoItem],
                        similar: ((PhotoItem, PhotoItem) -> Bool)? = nil) -> [MagazineSection] {
        let sorted = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        let grouped = Dictionary(grouping: sorted) { TimeBand.band(for: $0.creationDate) }
        let sim: (PhotoItem, PhotoItem) -> Bool = similar ?? { isBurstPair($0, $1) }

        var sections: [MagazineSection] = []
        for band in TimeBand.allCases {
            guard let group = grouped[band], !group.isEmpty else { continue }
            var blocks: [MagazineBlock] = []
            for (index, moment) in splitMoments(group).enumerated() {
                blocks.append(contentsOf: makeBlocks(moment, seed: index, similar: sim))
            }
            if group.count >= 4, let phrase = quotePhrase(for: band) {
                blocks.insert(MagazineBlock(template: .quote, items: [], caption: phrase), at: 0)
            }
            let anchor = group.first(where: { $0.location != nil })?.location
            sections.append(MagazineSection(
                band: band,
                timeText: timeRange(group),
                placeName: nil,
                anchorLocation: anchor,
                blocks: blocks
            ))
        }
        return sections
    }

    // MARK: - Moments

    private static func splitMoments(_ items: [PhotoItem]) -> [[PhotoItem]] {
        var moments: [[PhotoItem]] = []
        var current: [PhotoItem] = []
        for item in items {
            if let last = current.last {
                let gap = abs((item.creationDate ?? .distantPast)
                    .timeIntervalSince(last.creationDate ?? .distantPast))
                let jumped = distance(last, item).map { $0 > momentDistance } ?? false
                if gap > momentGap || jumped {
                    moments.append(current)
                    current = []
                }
            }
            current.append(item)
        }
        if !current.isEmpty { moments.append(current) }
        return moments
    }

    private static func makeBlocks(_ moment: [PhotoItem], seed: Int,
                                   similar: (PhotoItem, PhotoItem) -> Bool) -> [MagazineBlock] {
        var blocks: [MagazineBlock] = []
        var run: [PhotoItem] = []

        func flush() {
            guard !run.isEmpty else { return }
            blocks.append(contentsOf: layoutRun(run, seed: seed + blocks.count))
            run.removeAll()
        }

        var i = 0
        while i < moment.count {
            var j = i + 1
            while j < moment.count && similar(moment[j - 1], moment[j]) { j += 1 }
            if j - i >= 3 {
                flush()
                blocks.append(MagazineBlock(template: .stack, items: Array(moment[i..<j])))
                i = j
            } else {
                run.append(moment[i])
                i += 1
            }
        }
        flush()
        return blocks
    }

    private static func layoutRun(_ run: [PhotoItem], seed: Int) -> [MagazineBlock] {
        var blocks: [MagazineBlock] = []
        var index = 0
        var s = seed
        while index < run.count {
            let remaining = run.count - index
            if remaining >= 3 && s % 5 == 2 {
                blocks.append(MagazineBlock(template: .trio, items: Array(run[index..<index + 3])))
                index += 3
            } else if remaining >= 3 && s % 3 != 0 {
                let n = (remaining >= 4 && s % 2 == 0) ? 4 : 3
                blocks.append(MagazineBlock(template: .collage, items: Array(run[index..<index + n])))
                index += n
            } else if remaining >= 2 && s % 2 == 0 {
                blocks.append(MagazineBlock(template: .duo, items: Array(run[index..<index + 2])))
                index += 2
            } else {
                let template: BlockTemplate = (s % 4 == 0) ? .hero : .single
                blocks.append(MagazineBlock(template: template, items: [run[index]]))
                index += 1
            }
            s += 1
        }
        return blocks
    }

    // MARK: - Helpers

    private static func isBurstPair(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        if let ba = a.burstIdentifier, let bb = b.burstIdentifier, ba == bb { return true }
        let gap = abs((b.creationDate ?? .distantPast)
            .timeIntervalSince(a.creationDate ?? .distantPast))
        guard gap <= burstGap else { return false }
        if let d = distance(a, b) { return d <= burstDistance }
        return true
    }

    private static func distance(_ a: PhotoItem, _ b: PhotoItem) -> CLLocationDistance? {
        guard let la = a.location, let lb = b.location else { return nil }
        return la.distance(from: lb)
    }

    private static func quotePhrase(for band: TimeBand) -> String? {
        switch band {
        case .dawn: return "在还没醒来的城市里"
        case .morning: return "上午的光，刚刚好"
        case .noon: return "正午，时间慢了下来"
        case .afternoon: return "午后的一段闲散时光"
        case .evening: return "天色渐暗的时候"
        case .night: return "夜色收纳了这一天"
        }
    }

    private static func timeRange(_ items: [PhotoItem]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let dates = items.compactMap { $0.creationDate }.sorted()
        guard let first = dates.first else { return "" }
        guard let last = dates.last, last != first else { return formatter.string(from: first) }
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }
}
