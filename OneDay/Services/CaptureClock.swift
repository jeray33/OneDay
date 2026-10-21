import Foundation
import Photos

/// The single source of truth for "which day" and "what time" a capture
/// belongs to. A photo taken at 20:00 in Paris belongs to that Paris day and
/// reads 20:00, not to the next day at 02:00 Beijing time.
///
/// Day keys keep the app's existing representation: the device calendar's
/// midnight of the capture's *local* calendar date. Navigation, comparison
/// and display of day keys therefore stay unchanged; only the mapping from a
/// capture to its key goes through here.
///
/// Zone per capture: its own coordinate, else the zone of the nearest-in-time
/// located capture within `inferenceWindow`, else the device zone. Every
/// caller must feed the same population (all supported media, own library
/// plus shared albums) so a capture lands on the same day everywhere.
nonisolated struct CaptureClock: Sendable {
    static let enabledKey = "OneDay.localCaptureTime"
    /// How far in time a located capture lends its zone to unlocated ones.
    static let inferenceWindow: TimeInterval = 6 * 3600
    /// Widening a device-zone day by this much on each side covers every
    /// capture whose local date can equal that day (UTC-12 … UTC+14 against
    /// any device zone), plus the inference window.
    static let fetchMargin: TimeInterval = 27 * 3600 + inferenceWindow

    struct Sample: Sendable {
        let date: Date?
        let latitude: Double?
        let longitude: Double?

        init(date: Date?, latitude: Double? = nil, longitude: Double? = nil) {
            self.date = date
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The device calendar; its time zone is the fallback zone.
    let calendar: Calendar
    let isEnabled: Bool
    private let zoneAt: @Sendable (Double, Double) -> TimeZone?

    init(calendar: Calendar = .current,
         isEnabled: Bool = true,
         zoneAt: @escaping @Sendable (Double, Double) -> TimeZone?) {
        self.calendar = calendar
        self.isEnabled = isEnabled
        self.zoneAt = zoneAt
    }

    static var isEnabledSetting: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The live clock: the bundled zone grid unless the user turned
    /// capture-local time off (or the grid failed to load), in which case
    /// every capture uses the device zone, exactly as before this existed.
    static func current() -> CaptureClock {
        let index = TimeZoneIndex.shared
        let enabled = isEnabledSetting && index != nil
        return CaptureClock(isEnabled: enabled) { latitude, longitude in
            index?.timeZone(latitude: latitude, longitude: longitude)
        }
    }

    var deviceZone: TimeZone { calendar.timeZone }

    // MARK: Zones

    /// One zone per sample, aligned with `samples` (any order).
    func timeZones(for samples: [Sample]) -> [TimeZone] {
        let device = deviceZone
        guard isEnabled, !samples.isEmpty else {
            return Array(repeating: device, count: samples.count)
        }
        var direct: [TimeZone?] = samples.map { sample in
            guard let latitude = sample.latitude, let longitude = sample.longitude else { return nil }
            return zoneAt(latitude, longitude)
        }

        let order = samples.indices
            .filter { samples[$0].date != nil }
            .sorted { samples[$0].date! < samples[$1].date! }
        var previous: [Int?] = Array(repeating: nil, count: samples.count)
        var next: [Int?] = Array(repeating: nil, count: samples.count)
        var last: Int?
        for index in order {
            previous[index] = last
            if direct[index] != nil { last = index }
        }
        last = nil
        for index in order.reversed() {
            next[index] = last
            if direct[index] != nil { last = index }
        }

        for index in order where direct[index] == nil {
            let date = samples[index].date!
            let before = previous[index].map { (gap: date.timeIntervalSince(samples[$0].date!), index: $0) }
            let after = next[index].map { (gap: samples[$0].date!.timeIntervalSince(date), index: $0) }
            let nearest = [before, after]
                .compactMap { $0 }
                .filter { $0.gap <= Self.inferenceWindow }
                .min { $0.gap < $1.gap }
            if let nearest { direct[index] = direct[nearest.index] }
        }
        return direct.map { $0 ?? device }
    }

    // MARK: Days and times

    /// The device-calendar midnight of `date`'s calendar date in `zone`.
    func dayKey(for date: Date, in zone: TimeZone) -> Date {
        if zone.identifier == deviceZone.identifier {
            return calendar.startOfDay(for: date)
        }
        let local = localCalendar(zone)
        let parts = local.dateComponents([.era, .year, .month, .day], from: date)
        guard let day = calendar.date(from: parts) else { return calendar.startOfDay(for: date) }
        return calendar.startOfDay(for: day)
    }

    /// The device calendar re-anchored to `zone`, for local hours and labels.
    func localCalendar(_ zone: TimeZone) -> Calendar {
        var local = calendar
        local.timeZone = zone
        return local
    }

    /// "UTC+2"-style label, or nil when `zone` reads the same as the device
    /// zone at `date`.
    func offsetLabel(for zone: TimeZone, at date: Date) -> String? {
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds != deviceZone.secondsFromGMT(for: date) else { return nil }
        let sign = seconds >= 0 ? "+" : "-"
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        return minutes == 0
            ? "UTC\(sign)\(hours)"
            : String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }
}

// MARK: - PHAsset bridge

nonisolated extension CaptureClock.Sample {
    init(asset: PHAsset) {
        let coordinate = asset.location?.coordinate
        self.init(date: asset.creationDate,
                  latitude: coordinate?.latitude,
                  longitude: coordinate?.longitude)
    }
}

nonisolated extension CaptureClock {
    /// Zone and day key per asset, aligned with `assets`. Pass every
    /// supported asset around the dates of interest (own library plus shared
    /// albums) so unlocated captures infer from the same neighbors everywhere.
    func days(for assets: [PHAsset]) -> [(zone: TimeZone, day: Date?)] {
        guard isEnabled else {
            // Off: no location reads at all, exactly the pre-existing grouping.
            let zone = deviceZone
            return assets.map { (zone, $0.creationDate.map(calendar.startOfDay(for:))) }
        }
        let zones = timeZones(for: assets.map(CaptureClock.Sample.init(asset:)))
        return zip(assets, zones).map { asset, zone in
            (zone, asset.creationDate.map { dayKey(for: $0, in: zone) })
        }
    }
}
