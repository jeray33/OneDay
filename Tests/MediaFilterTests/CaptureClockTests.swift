import XCTest
@testable import MediaFilter

final class CaptureClockTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let paris = TimeZone(identifier: "Europe/Paris")!

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// Paris near (48.85, 2.35); everything else unknown.
    private func clock(enabled: Bool = true, device: TimeZone? = nil) -> CaptureClock {
        let paris = self.paris
        return CaptureClock(calendar: calendar(device ?? shanghai), isEnabled: enabled) { latitude, _ in
            latitude > 40 ? paris : nil
        }
    }

    private let parisSpot = (latitude: 48.85, longitude: 2.35)

    // MARK: Day keys

    func testParisEveningBelongsToTheParisDay() {
        // 2025-10-15 20:00 in Paris (UTC+2) is 2025-10-16 02:00 in Beijing.
        let shot = date("2025-10-15T18:00:00Z")
        let clock = clock()
        let zones = clock.timeZones(for: [.init(date: shot, latitude: parisSpot.latitude, longitude: parisSpot.longitude)])
        XCTAssertEqual(zones, [paris])
        let expected = calendar(shanghai).date(from: DateComponents(year: 2025, month: 10, day: 15))!
        XCTAssertEqual(clock.dayKey(for: shot, in: zones[0]), expected)
        XCTAssertEqual(clock.localCalendar(zones[0]).component(.hour, from: shot), 20)
    }

    func testDisabledClockMatchesTheDeviceCalendarExactly() {
        let clock = clock(enabled: false)
        let samples: [CaptureClock.Sample] = (0..<48).map { hour in
            .init(date: date("2025-10-15T00:00:00Z").addingTimeInterval(Double(hour) * 3600),
                  latitude: parisSpot.latitude, longitude: parisSpot.longitude)
        }
        let zones = clock.timeZones(for: samples)
        XCTAssertTrue(zones.allSatisfy { $0 == shanghai })
        for (sample, zone) in zip(samples, zones) {
            XCTAssertEqual(clock.dayKey(for: sample.date!, in: zone),
                           calendar(shanghai).startOfDay(for: sample.date!))
        }
    }

    func testDeviceZoneCapturesKeepTheirPreviousDayKeys() {
        // A domestic library must be unaffected: every key equals startOfDay.
        let clock = CaptureClock(calendar: calendar(shanghai)) { _, _ in self.shanghai }
        for hour in stride(from: 0, to: 72, by: 1) {
            let shot = date("2025-03-01T00:00:00Z").addingTimeInterval(Double(hour) * 3600 + 59)
            let zone = clock.timeZones(for: [.init(date: shot, latitude: 39.9, longitude: 116.4)])[0]
            XCTAssertEqual(clock.dayKey(for: shot, in: zone), calendar(shanghai).startOfDay(for: shot))
        }
    }

    func testDateLineZonesMapToTheirOwnLocalDates() {
        let kiribati = TimeZone(identifier: "Pacific/Kiritimati")! // UTC+14
        let honolulu = TimeZone(identifier: "Pacific/Honolulu")!   // UTC-10
        let clock = clock()
        let shot = date("2025-06-01T11:30:00Z")
        let device = calendar(shanghai)
        XCTAssertEqual(clock.dayKey(for: shot, in: kiribati),
                       device.date(from: DateComponents(year: 2025, month: 6, day: 2)))
        XCTAssertEqual(clock.dayKey(for: shot, in: honolulu),
                       device.date(from: DateComponents(year: 2025, month: 6, day: 1)))
    }

    func testFetchMarginCoversEveryZoneAgainstEveryDeviceZone() {
        // Any capture whose local date equals day D must fall inside the
        // widened device-zone window used by `items(on:)`.
        let offsets = stride(from: -12 * 3600, through: 14 * 3600, by: 1800)
        for deviceOffset in offsets {
            let device = TimeZone(secondsFromGMT: deviceOffset)!
            let clock = CaptureClock(calendar: calendar(device)) { _, _ in nil }
            let day = calendar(device).date(from: DateComponents(year: 2025, month: 7, day: 10))!
            let end = calendar(device).date(byAdding: .day, value: 1, to: day)!
            for captureOffset in offsets {
                let zone = TimeZone(secondsFromGMT: captureOffset)!
                let localStart = calendar(zone).date(from: DateComponents(year: 2025, month: 7, day: 10))!
                for shot in [localStart, localStart.addingTimeInterval(86_399)] {
                    XCTAssertEqual(clock.dayKey(for: shot, in: zone), day)
                    XCTAssertGreaterThanOrEqual(shot, day.addingTimeInterval(-CaptureClock.fetchMargin))
                    XCTAssertLessThan(shot, end.addingTimeInterval(CaptureClock.fetchMargin))
                }
            }
        }
    }

    // MARK: Inference

    func testUnlocatedCaptureBorrowsTheNearestLocatedZoneWithinSixHours() {
        let clock = clock()
        let base = date("2025-10-15T10:00:00Z")
        let samples: [CaptureClock.Sample] = [
            .init(date: base, latitude: parisSpot.latitude, longitude: parisSpot.longitude),
            .init(date: base.addingTimeInterval(2 * 3600)),           // 2 h after Paris
            .init(date: base.addingTimeInterval(7 * 3600)),           // 7 h after: too far
            .init(date: base.addingTimeInterval(-5 * 3600)),          // 5 h before Paris
        ]
        XCTAssertEqual(clock.timeZones(for: samples), [paris, paris, shanghai, paris])
    }

    func testInferencePrefersTheCloserNeighborInTime() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let paris = self.paris
        let clock = CaptureClock(calendar: calendar(shanghai)) { latitude, _ in
            latitude > 40 ? paris : tokyo
        }
        let base = date("2025-10-15T10:00:00Z")
        let samples: [CaptureClock.Sample] = [
            .init(date: base.addingTimeInterval(3 * 3600)),               // unlocated
            .init(date: base, latitude: 48.85, longitude: 2.35),          // Paris, 3 h before
            .init(date: base.addingTimeInterval(4 * 3600), latitude: 35.68, longitude: 139.69), // Tokyo, 1 h after
        ]
        XCTAssertEqual(clock.timeZones(for: samples), [tokyo, paris, tokyo])
    }

    func testUndatedSamplesFallBackToTheDeviceZone() {
        let zones = clock().timeZones(for: [.init(date: nil)])
        XCTAssertEqual(zones, [shanghai])
    }

    // MARK: Entry-point consistency

    /// Mirrors the three ways the app assigns days: the whole library
    /// (`eligibleDays`), a day's widened fetch window (`items(on:)`), and one
    /// capture with its ±6 h neighbors (`captureDay(for:)`). A capture must
    /// get the same day from all three, or a listed day could open empty.
    func testWholeLibraryWindowedDayAndSingleCaptureAgree() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let paris = self.paris
        let shanghai = self.shanghai
        let clock = CaptureClock(calendar: calendar(shanghai)) { latitude, longitude in
            if latitude > 40 { return paris }
            return longitude > 130 ? tokyo : shanghai
        }
        // A trip: Paris days, a flight with unlocated shots, Tokyo, home.
        var samples: [CaptureClock.Sample] = []
        var cursor = date("2025-10-12T06:00:00Z")
        let spots: [(Double, Double)?] = [(48.85, 2.35), nil, (48.86, 2.34), nil, nil,
                                          (35.68, 139.69), nil, (39.90, 116.40), nil]
        var generator = SystemRandomNumberGenerator()
        for step in 0..<400 {
            let spot = spots[(step / 40) % spots.count]
            samples.append(.init(date: cursor, latitude: spot?.0, longitude: spot?.1))
            cursor = cursor.addingTimeInterval(Double.random(in: 300...5400, using: &generator))
        }

        let all = clock.timeZones(for: samples)
        let wholeLibrary = zip(samples, all).map { clock.dayKey(for: $0.date!, in: $1) }

        let device = calendar(shanghai)
        for day in Set(wholeLibrary) {
            let end = device.date(byAdding: .day, value: 1, to: day)!
            let windowIndices = samples.indices.filter {
                samples[$0].date! >= day.addingTimeInterval(-CaptureClock.fetchMargin)
                    && samples[$0].date! < end.addingTimeInterval(CaptureClock.fetchMargin)
            }
            let window = windowIndices.map { samples[$0] }
            let zones = clock.timeZones(for: window)
            let windowed = Set(zip(windowIndices, zip(window, zones))
                .filter { clock.dayKey(for: $0.1.0.date!, in: $0.1.1) == day }
                .map(\.0))
            let expected = Set(samples.indices.filter { wholeLibrary[$0] == day })
            XCTAssertEqual(windowed, expected, "day \(day)")
        }

        for index in samples.indices {
            let center = samples[index].date!
            let neighbors = samples.indices.filter {
                $0 != index && abs(samples[$0].date!.timeIntervalSince(center)) <= CaptureClock.inferenceWindow
            }
            let population = [samples[index]] + neighbors.map { samples[$0] }
            let zone = clock.timeZones(for: population)[0]
            XCTAssertEqual(clock.dayKey(for: center, in: zone), wholeLibrary[index])
        }
    }

    // MARK: Labels

    func testOffsetLabelFollowsDaylightSavingAndHidesTheDeviceOffset() {
        let clock = clock()
        XCTAssertEqual(clock.offsetLabel(for: paris, at: date("2025-07-01T12:00:00Z")), "UTC+2")
        XCTAssertEqual(clock.offsetLabel(for: paris, at: date("2025-12-01T12:00:00Z")), "UTC+1")
        XCTAssertNil(clock.offsetLabel(for: shanghai, at: date("2025-07-01T12:00:00Z")))
        let india = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(clock.offsetLabel(for: india, at: date("2025-07-01T12:00:00Z")), "UTC+5:30")
    }

    // MARK: Bundled grid

    func testBundledGridResolvesKnownPlaces() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OneDay/Resources/GeoNamesTimeZones.dat")
        let index = try XCTUnwrap(TimeZoneIndex(contentsOf: url))
        XCTAssertGreaterThan(index.cellCount, 50_000)

        func zone(_ latitude: Double, _ longitude: Double) -> String? {
            index.timeZone(latitude: latitude, longitude: longitude)?.identifier
        }
        XCTAssertEqual(zone(48.8584, 2.2945), "Europe/Paris")
        XCTAssertEqual(zone(43.6950, 7.2700), "Europe/Paris")       // Nice
        XCTAssertEqual(zone(43.7396, 7.4270), "Europe/Monaco")
        XCTAssertEqual(zone(47.0502, 8.3093), "Europe/Zurich")      // Luzern
        XCTAssertEqual(zone(39.9087, 116.3975), "Asia/Shanghai")    // Beijing
        XCTAssertEqual(zone(35.6895, 139.6917), "Asia/Tokyo")
        XCTAssertEqual(zone(40.7580, -73.9855), "America/New_York")
        XCTAssertEqual(zone(43.55, 7.35), "Europe/Paris")           // ~20 km off Nice, at sea
        XCTAssertNil(zone(-30.0, -140.0))                            // open Pacific
        // Repeated lookups are served from the memo with the same answer.
        XCTAssertEqual(zone(48.8584, 2.2945), "Europe/Paris")
    }

    func testCorruptGridIsRejected() {
        XCTAssertNil(TimeZoneIndex(data: Data("nope".utf8)))
        XCTAssertNil(TimeZoneIndex(data: Data("TZG1".utf8) + Data([5, 0])))
    }
}
