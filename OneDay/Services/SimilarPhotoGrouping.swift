import Foundation

nonisolated enum SimilarPhotoFolding: String, CaseIterable, Identifiable {
    case off, nearDuplicate, sameScene, loose, veryLoose, custom
    static let storageKey = "OneDay.similarPhotoFolding"
    var id: Self { self }
    var label: String {
        switch self {
        case .off: return "关闭"
        case .nearDuplicate: return "几乎相同"
        case .sameScene: return "同一场景"
        case .loose: return "宽松"
        case .veryLoose: return "很宽松"
        case .custom: return "自定义"
        }
    }
    // Conservative starting points for Vision revision 2, not calibrated guarantees.
    var parameters: SimilarPhotoFoldingParameters {
        switch self {
        case .off, .nearDuplicate: return .init(threshold: 0.28, window: 30)
        case .sameScene: return .init(threshold: 0.48, window: 120)
        case .loose, .custom: return .init(threshold: 0.60, window: 300)
        case .veryLoose: return .init(threshold: 0.72, window: 600)
        }
    }
    var threshold: Float { parameters.threshold }
    var window: TimeInterval { parameters.window }
    static var enabledCases: [Self] { allCases.filter { $0 != .off } }
}

nonisolated struct SimilarPhotoFoldingParameters: Equatable {
    static let thresholdOptions: [Float] = (0...30).map { Float(20 + $0 * 2) / 100 }
    static let windowOptions: [TimeInterval] = [30, 60, 120, 300, 600]
    let threshold: Float
    let window: TimeInterval

    init(threshold: Float = 0.60, window: TimeInterval = 300) {
        let value = threshold.isFinite ? min(0.80, max(0.20, threshold)) : 0.60
        self.threshold = Float((Double(value) * 50).rounded() / 50)
        self.window = Self.windowOptions.contains(window) ? window : 300
    }

    static func windowLabel(_ window: TimeInterval) -> String {
        window == 30 ? "30 秒" : "\(Int(window / 60)) 分钟"
    }

    var summary: String {
        "\(String(format: "%.2f", threshold)) / \(Self.windowLabel(window))"
    }
}

nonisolated struct SimilarPhotoFoldingPreferences: Equatable {
    static let lastEnabledKey = "OneDay.similarPhotoFolding.lastEnabled"
    static let thresholdKey = "OneDay.similarPhotoFolding.customThreshold"
    static let windowKey = "OneDay.similarPhotoFolding.customWindow"
    private(set) var level: SimilarPhotoFolding
    private(set) var lastEnabledLevel: SimilarPhotoFolding
    private(set) var customParameters: SimilarPhotoFoldingParameters

    init(defaults: UserDefaults = .standard) {
        let level = SimilarPhotoFolding(rawValue: defaults.string(forKey: SimilarPhotoFolding.storageKey) ?? "")
            ?? .nearDuplicate
        self.level = level
        let saved = SimilarPhotoFolding(rawValue: defaults.string(forKey: Self.lastEnabledKey) ?? "")
        lastEnabledLevel = saved.flatMap { $0 == .off ? nil : $0 }
            ?? (level == .off ? .nearDuplicate : level)
        customParameters = .init(
            threshold: (defaults.object(forKey: Self.thresholdKey) as? NSNumber)?.floatValue ?? 0.60,
            window: (defaults.object(forKey: Self.windowKey) as? NSNumber)?.doubleValue ?? 300)
    }

    var isEnabled: Bool {
        get { level != .off }
        set {
            if newValue {
                if level == .off { select(lastEnabledLevel) }
            } else { select(.off) }
        }
    }

    var parameters: SimilarPhotoFoldingParameters {
        let active = level == .off ? lastEnabledLevel : level
        return active == .custom ? customParameters : active.parameters
    }

    mutating func select(_ level: SimilarPhotoFolding) {
        if level == .off {
            if self.level != .off { lastEnabledLevel = self.level }
        } else { lastEnabledLevel = level }
        self.level = level
    }

    mutating func setThreshold(_ threshold: Float) {
        customParameters = .init(threshold: threshold, window: parameters.window)
        select(.custom)
    }

    mutating func setWindow(_ window: TimeInterval) {
        customParameters = .init(threshold: parameters.threshold, window: window)
        select(.custom)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(level.rawValue, forKey: SimilarPhotoFolding.storageKey)
        defaults.set(lastEnabledLevel.rawValue, forKey: Self.lastEnabledKey)
        defaults.set(customParameters.threshold, forKey: Self.thresholdKey)
        defaults.set(customParameters.window, forKey: Self.windowKey)
    }
}

nonisolated enum SimilarPhotoGrouping {
    /// Input order is preserved. Compare against both the previous and first
    /// member so a chain of small changes cannot absorb an entire day.
    static func groups<Item>(
        _ items: [Item], level: SimilarPhotoFolding,
        parameters: SimilarPhotoFoldingParameters? = nil,
        date: (Item) -> Date?, eligible: (Item) -> Bool,
        distance: (Item, Item) -> Float?,
        compatible: (Item, Item) -> Bool = { _, _ in true },
        nearby: (Item, Item) -> Bool = { _, _ in true }
    ) -> [[Item]] {
        let parameters = parameters ?? level.parameters
        var result: [[Item]] = []
        for item in items {
            if level != .off, eligible(item),
               let group = result.last, let first = group.first, let last = group.last,
               compatible(first, item), compatible(last, item),
               eligible(last), let start = date(first), let end = date(item),
               end >= start, end.timeIntervalSince(start) <= parameters.window,
               nearby(first, item),
               let previousDistance = distance(last, item),
               let firstDistance = distance(first, item),
               previousDistance.isFinite, firstDistance.isFinite,
               previousDistance <= parameters.threshold, firstDistance <= parameters.threshold {
                result[result.count - 1].append(item)
            } else {
                result.append([item])
            }
        }
        return result
    }
}

nonisolated enum VideoSimilarityPolicy {
    static let frameFractions: [Double] = [0.1, 0.5, 0.9]

    static func sampleTimes(duration: TimeInterval) -> [TimeInterval] {
        guard duration.isFinite, duration >= 0.5 else { return [] }
        return frameFractions.map { duration * $0 }
    }

    static func compatibleDurations(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        guard a.isFinite, b.isFinite, a >= 0.5, b >= 0.5 else { return false }
        return abs(a - b) <= max(0.5, min(2, min(a, b) * 0.15))
    }

    /// Every corresponding sample must match, not just the cover or mean.
    static func distance(_ distances: [Float]) -> Float? {
        guard distances.count == frameFractions.count,
              distances.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return distances.max()
    }
}
