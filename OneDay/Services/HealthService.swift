import Foundation
import HealthKit

/// Read-only access to the user's Health data for the day page's insights
/// strip: step count and the logged state of mind. Authorization is
/// requested lazily on first use; a denial simply yields nil so the strip
/// hides that entry. Results are cached per day within the session.
actor HealthService {
    static let shared = HealthService()

    /// A day's logged state of mind reduced to one short Chinese label.
    struct DayMood: Equatable {
        /// e.g. "心情不错"
        let title: String
        /// HealthKit's valence in -1...1, kept for future styling.
        let valence: Double
    }

    private let store = HKHealthStore()
    private var authorizationRequested = false
    private var stepsCache: [String: Int] = [:]
    private var stepsMisses: Set<String> = []
    private var moodCache: [String: DayMood] = [:]
    private var moodMisses: Set<String> = []

    private func ensureAuthorization() async {
        guard !authorizationRequested, HKHealthStore.isHealthDataAvailable() else { return }
        authorizationRequested = true
        let read: Set<HKObjectType> = [
            HKQuantityType(.stepCount),
            HKObjectType.stateOfMindType(),
        ]
        try? await store.requestAuthorization(toShare: [], read: read)
    }

    private static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayInterval(for date: Date) -> (start: Date, end: Date)? {
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// Total step count for the given day; nil when unavailable or denied.
    func steps(on date: Date) async -> Int? {
        let key = Self.dayKey(for: date)
        if let cached = stepsCache[key] { return cached }
        if stepsMisses.contains(key) { return nil }
        await ensureAuthorization()
        guard HKHealthStore.isHealthDataAvailable(),
              let interval = Self.dayInterval(for: date) else {
            stepsMisses.insert(key)
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let sum: Double? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()))
            }
            store.execute(query)
        }
        guard let sum, sum > 0 else {
            stepsMisses.insert(key)
            return nil
        }
        let value = Int(sum.rounded())
        stepsCache[key] = value
        return value
    }

    /// The day's state of mind: prefers the daily-mood entry, falls back to
    /// the last momentary emotion logged that day. Nil when the user never
    /// logged one or access is denied.
    func mood(on date: Date) async -> DayMood? {
        let key = Self.dayKey(for: date)
        if let cached = moodCache[key] { return cached }
        if moodMisses.contains(key) { return nil }
        await ensureAuthorization()
        guard HKHealthStore.isHealthDataAvailable(),
              let interval = Self.dayInterval(for: date) else {
            moodMisses.insert(key)
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let samples: [HKStateOfMind] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.stateOfMindType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKStateOfMind]) ?? [])
            }
            store.execute(query)
        }
        guard let sample = samples.first(where: { $0.kind == .dailyMood }) ?? samples.first else {
            moodMisses.insert(key)
            return nil
        }
        let mood = DayMood(title: Self.title(forValence: sample.valence), valence: sample.valence)
        moodCache[key] = mood
        return mood
    }

    private static func title(forValence valence: Double) -> String {
        switch valence {
        case 0.5...: return "心情明媚"
        case 0.15..<0.5: return "心情不错"
        case (-0.15)..<0.15: return "心情平静"
        case (-0.5)..<(-0.15): return "有点低落"
        default: return "心情低落"
        }
    }
}
