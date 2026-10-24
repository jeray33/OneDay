import XCTest
@testable import MediaFilter

final class OfflinePlaceIndexTests: XCTestCase {
    private let index = OfflinePlaceIndex(tsv: """
    48.8534\t2.3488\tFR\t2138551\tParis\t巴黎
    48.8350\t2.2410\tFR\t121334\tBoulogne-Billancourt\t布洛涅-比扬古
    48.8240\t2.2700\tFR\t68451\tIssy-les-Moulineaux\t
    43.7031\t7.2661\tFR\t342669\tNice\t尼斯
    43.7384\t7.4246\tMC\t32965\tMonaco\t摩納哥|摩纳哥
    43.5513\t7.0127\tFR\t74545\tCannes\t康城|戛纳
    46.2022\t6.1457\tCH\t183981\tGenève\t日內瓦
    35.6895\t139.6917\tJP\t8336599\tTokyo\t東京
    """)

    func testSpotInsideBigCityPrefersTheCityOverACloserSuburbCenter() {
        // Near the Eiffel Tower: Issy's center is about as close as Paris'
        // own, but Paris' population-derived radius covers the spot.
        let place = index.nearest(latitude: 48.8584, longitude: 2.2945)
        XCTAssertEqual(place?.name, "Paris")
    }

    func testSmallTownWinsWhenThePhotoIsAtItsCenter() {
        let place = index.nearest(latitude: 48.8352, longitude: 2.2405)
        XCTAssertEqual(place?.name, "Boulogne-Billancourt")
    }

    func testFarFromAnyTownReturnsNil() {
        XCTAssertNil(index.nearest(latitude: 0, longitude: -30))
    }

    func testSearchCrossesGridCellBoundaries() {
        // Just across the 7° meridian from Nice's cell.
        XCTAssertEqual(index.nearest(latitude: 43.76, longitude: 6.999)?.name, "Nice")
    }

    func testSimplifiedChineseDisplayNamePrefersNativeSimplifiedForm() {
        let monaco = index.nearest(latitude: 43.7384, longitude: 7.4246)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: monaco, languageCode: "zh", script: "Hans"), "摩纳哥")
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: monaco, languageCode: "zh", script: "Hant"), "摩納哥")
    }

    func testScriptSpecificNameBeatsARegionNeutralOne() {
        let cannes = index.nearest(latitude: 43.5513, longitude: 7.0127)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: cannes, languageCode: "zh", script: "Hans"), "戛纳")
    }

    func testTraditionalOnlyNameIsConvertedToSimplified() {
        let geneva = index.nearest(latitude: 46.20, longitude: 6.15)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: geneva, languageCode: "zh", script: "Hans"), "日内瓦")
        let tokyo = index.nearest(latitude: 35.69, longitude: 139.69)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: tokyo, languageCode: "zh", script: "Hans"), "东京")
    }

    func testBundledDataResolvesKnownEuropeanSpots() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OneDay/Resources/GeoNamesCities.dat")
        let index = try XCTUnwrap(OfflinePlaceIndex.load(from: url))
        XCTAssertGreaterThan(index.count, 100_000)

        func name(_ lat: Double, _ lon: Double) -> String? {
            index.nearest(latitude: lat, longitude: lon).map {
                OfflinePlaceIndex.displayName(for: $0, languageCode: "zh", script: "Hans")
            }
        }
        XCTAssertEqual(name(48.8584, 2.2945), "巴黎")          // Eiffel Tower
        XCTAssertEqual(name(48.8606, 2.3376), "巴黎")          // Louvre
        XCTAssertEqual(name(43.6950, 7.2700), "尼斯")          // Promenade des Anglais
        XCTAssertEqual(name(43.7396, 7.4270), "Monaco")        // Monte-Carlo casino
        XCTAssertEqual(name(47.0502, 8.3093), "卢塞恩")        // Kapellbrücke
        XCTAssertEqual(name(47.3769, 8.5417), "苏黎世")        // Zürich HB
    }

    func testMissingHanNameOrNonChineseLanguageFallsBackToLocalName() {
        let issy = index.nearest(latitude: 48.8240, longitude: 2.2700)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: issy, languageCode: "zh", script: "Hans"), "Issy-les-Moulineaux")
        let geneva = index.nearest(latitude: 46.20, longitude: 6.15)!
        XCTAssertEqual(OfflinePlaceIndex.displayName(for: geneva, languageCode: "en", script: nil), "Genève")
    }

    func testBundledGeoNamesFallbackFeedsForeignStopTitlesAndMerging() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OneDay/Resources/GeoNamesCities.dat")
        let index = try XCTUnwrap(OfflinePlaceIndex.load(from: url))
        let coordinates = [(48.8584, 2.2945), (48.8606, 2.3376), (43.6950, 7.2700)]
        let states = try coordinates.map { latitude, longitude -> PlaceNaming.StopPlace in
            let place = try XCTUnwrap(index.nearest(latitude: latitude, longitude: longitude))
            let fields = PlaceFields(
                locality: OfflinePlaceIndex.displayName(for: place, languageCode: "zh", script: "Hans"),
                countryCode: place.countryCode)
            guard case .resolved(let resolved) = PlaceNaming.withGeoNamesFallback(.failed, lookup: { fields })
            else { throw NSError(domain: "GeoNamesFallbackTest", code: 1) }
            return .resolved(resolved)
        }
        let titles = PlaceNaming.stopTitles(for: states)
        XCTAssertEqual(titles, [.title("巴黎"), .title("巴黎"), .title("尼斯")])
        XCTAssertEqual(PlaceNaming.stopGroups(for: titles), [[0, 1], [2]])
    }
}
