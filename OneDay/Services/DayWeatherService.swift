import CoreLocation
import Foundation
import WeatherKit

/// One day's weather reduced to what the insights strip shows.
struct DayWeather: Equatable, Codable {
    /// Localized condition text, e.g. "晴".
    let condition: String
    /// SF Symbol name for the condition.
    let symbolName: String
    let highCelsius: Double
    let lowCelsius: Double
}

/// Historical daily weather for the day page, backed by WeatherKit
/// (`WeatherQuery.daily(startDate:endDate:)`). Results are cached on disk
/// per (day, ~0.5° coordinate grid): past weather never changes, so a day
/// is fetched at most once, keeping us far under the free monthly quota.
actor DayWeatherService {
    static let shared = DayWeatherService()

    private var memory: [String: DayWeather] = [:]
    /// Failed keys with their failure time; retried after an hour.
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<DayWeather?, Never>] = [:]
    private var loadedDiskCache = false

    /// WeatherKit historical data starts on Aug 1, 2021.
    private static let historicalFloor: Date = {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2021, month: 8, day: 1)) ?? .distantPast
    }()

    private var cacheURL: URL {
        // v2: condition text switched from WeatherKit's English strings to
        // explicit Chinese, so pre-v2 entries are invalidated by the rename.
        URL.cachesDirectory.appending(path: "OneDayDayWeather-v2.json")
    }

    private func loadDiskCacheIfNeeded() {
        guard !loadedDiskCache else { return }
        loadedDiskCache = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: DayWeather].self, from: data)
        else { return }
        memory.merge(decoded) { _, new in new }
    }

    private func persistDiskCache() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func key(for date: Date, at coordinate: CLLocationCoordinate2D) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let latGrid = (coordinate.latitude / 0.5).rounded() * 0.5
        let lonGrid = (coordinate.longitude / 0.5).rounded() * 0.5
        return String(format: "%04d-%02d-%02d@%.1f,%.1f",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, latGrid, lonGrid)
    }

    /// WeatherKit follows the app's localization, which is English-only, so
    /// conditions are mapped to Chinese explicitly to match the rest of the UI.
    private static func chineseCondition(_ condition: WeatherCondition) -> String {
        switch condition {
        case .clear: return "晴"
        case .mostlyClear: return "大部晴朗"
        case .partlyCloudy: return "局部多云"
        case .mostlyCloudy: return "多云"
        case .cloudy: return "阴"
        case .foggy: return "雾"
        case .haze: return "霾"
        case .smoky: return "烟雾"
        case .blowingDust: return "扬沙"
        case .breezy: return "微风"
        case .windy: return "大风"
        case .drizzle: return "毛毛雨"
        case .rain: return "雨"
        case .heavyRain: return "大雨"
        case .sunShowers: return "太阳雨"
        case .isolatedThunderstorms: return "局部雷暴"
        case .scatteredThunderstorms: return "分散雷暴"
        case .thunderstorms: return "雷阵雨"
        case .strongStorms: return "强风暴"
        case .freezingDrizzle: return "冻毛毛雨"
        case .freezingRain: return "冻雨"
        case .sleet: return "雨夹雪"
        case .wintryMix: return "雨雪混合"
        case .flurries: return "小阵雪"
        case .sunFlurries: return "晴间阵雪"
        case .snow: return "雪"
        case .heavySnow: return "大雪"
        case .blowingSnow: return "吹雪"
        case .blizzard: return "暴雪"
        case .hail: return "冰雹"
        case .frigid: return "严寒"
        case .hot: return "酷热"
        case .hurricane: return "飓风"
        case .tropicalStorm: return "热带风暴"
        @unknown default: return condition.description
        }
    }

    /// Weather for the given day at the given location; nil when the date is
    /// out of WeatherKit's historical range or the request fails.
    func weather(on date: Date, at coordinate: CLLocationCoordinate2D) async -> DayWeather? {
        guard date >= Self.historicalFloor else { return nil }
        let key = Self.key(for: date, at: coordinate)
        loadDiskCacheIfNeeded()
        if let cached = memory[key] { return cached }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 3600 { return nil }
        if let task = inFlight[key] { return await task.value }

        let task = Task<DayWeather?, Never> {
            let start = Calendar.current.startOfDay(for: date)
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
            do {
                let daily = try await WeatherService.shared.weather(
                    for: CLLocation(latitude: coordinate.latitude,
                                    longitude: coordinate.longitude),
                    including: .daily(startDate: start, endDate: end))
                guard let day = daily.first else { return nil }
                return DayWeather(
                    condition: Self.chineseCondition(day.condition),
                    symbolName: day.symbolName,
                    highCelsius: day.highTemperature.converted(to: .celsius).value,
                    lowCelsius: day.lowTemperature.converted(to: .celsius).value)
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory[key] = result
            persistDiskCache()
        } else {
            misses[key] = Date()
        }
        return result
    }
}
