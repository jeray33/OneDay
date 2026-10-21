import XCTest
@testable import MediaFilter

final class PlaceNamingTests: XCTestCase {
    // MARK: Fixtures

    private func fields(
        areaOfInterest: String? = nil, thoroughfare: String? = nil,
        subLocality: String? = nil, locality: String? = nil,
        administrativeArea: String? = nil, country: String? = nil,
        countryCode: String? = nil
    ) -> PlaceFields {
        PlaceFields(areaOfInterest: areaOfInterest, thoroughfare: thoroughfare,
                    subLocality: subLocality, locality: locality,
                    administrativeArea: administrativeArea, country: country,
                    countryCode: countryCode)
    }

    // 颐和园: POI inside 海淀区, 北京市.
    private let yiheyuan = PlaceFields(
        areaOfInterest: "颐和园", thoroughfare: "新建宫门路", subLocality: "海淀区",
        locality: "北京市", administrativeArea: "北京市", country: "中国", countryCode: "CN")
    // 街拍 on 成府路, same district.
    private let chengfulu = PlaceFields(
        thoroughfare: "成府路", subLocality: "海淀区",
        locality: "北京市", administrativeArea: "北京市", country: "中国", countryCode: "CN")
    private let zhongguancun = PlaceFields(
        thoroughfare: "中关村大街", subLocality: "海淀区",
        locality: "北京市", administrativeArea: "北京市", country: "中国", countryCode: "CN")
    // 三里屯一带, cross-district within 北京市.
    private let sanlitun = PlaceFields(
        thoroughfare: "工体北路", subLocality: "朝阳区",
        locality: "北京市", administrativeArea: "北京市", country: "中国", countryCode: "CN")
    // Sparse placemarks carrying only the city.
    private let beijingCity = PlaceFields(
        locality: "北京市", administrativeArea: "北京市", country: "中国", countryCode: "CN")
    private let shanghaiCity = PlaceFields(
        locality: "上海市", administrativeArea: "上海市", country: "中国", countryCode: "CN")
    // 渋谷: ward in `locality`, neighborhood in `subLocality`, no city level.
    private let shibuya = PlaceFields(
        subLocality: "道玄坂", locality: "渋谷区",
        administrativeArea: "東京都", country: "日本", countryCode: "JP")
    private let ebisu = PlaceFields(
        subLocality: "恵比寿", locality: "渋谷区",
        administrativeArea: "東京都", country: "日本", countryCode: "JP")
    // 浅草寺 POI in 台東区.
    private let asakusa = PlaceFields(
        areaOfInterest: "浅草寺", subLocality: "浅草", locality: "台東区",
        administrativeArea: "東京都", country: "日本", countryCode: "JP")
    // 横浜: city in `locality`, ward in `subLocality`, street in `thoroughfare`.
    private let yokohama = PlaceFields(
        thoroughfare: "山下町", subLocality: "中区", locality: "横浜市",
        administrativeArea: "神奈川県", country: "日本", countryCode: "JP")
    private let sanFrancisco = PlaceFields(
        thoroughfare: "Stanyan St", locality: "San Francisco",
        administrativeArea: "CA", country: "United States", countryCode: "US")
    private let hongKong = PlaceFields(
        subLocality: "中環", locality: "Hong Kong",
        administrativeArea: "Hong Kong", country: "中国香港", countryCode: "HK")

    private func titles(_ stops: [PlaceNaming.StopPlace]) -> [PlaceNaming.StopTitle] {
        PlaceNaming.stopTitles(for: stops)
    }

    private func resolved(_ fields: [PlaceFields]) -> [PlaceNaming.StopPlace] {
        fields.map { .resolved($0) }
    }

    private func names(_ stops: [PlaceNaming.StopPlace]) -> [String?] {
        titles(stops).map { title -> String? in
            guard case .title(let name) = title else { return nil }
            return name
        }
    }

    // MARK: Hierarchy mapping

    func testChineseHierarchyMapsDistrictAndCityAndDeduplicatesAdminLine() {
        let line = PlaceNaming.adminLine(yiheyuan)
        XCTAssertEqual(line, "中国 · 北京市 · 海淀区")
    }

    func testJapaneseHierarchyMapsWardCityAndNeighborhood() {
        // Tokyo ward: district from `locality`, neighborhood from `subLocalty`,
        // no city level (the 23 wards belong to no city).
        XCTAssertEqual(PlaceNaming.photoTitle(shibuya), "道玄坂 · 渋谷区")
        XCTAssertEqual(PlaceNaming.adminLine(shibuya), "日本 · 東京都 · 渋谷区")
        // Ordinance-designated city: city from `locality`, ward from
        // `subLocality`, street from `thoroughfare`.
        XCTAssertEqual(PlaceNaming.photoTitle(yokohama), "山下町 · 中区")
        XCTAssertEqual(PlaceNaming.adminLine(yokohama), "日本 · 神奈川県 · 横浜市 · 中区")
    }

    func testDefaultHierarchyMapsCityFromLocality() {
        XCTAssertEqual(PlaceNaming.photoTitle(sanFrancisco), "Stanyan St · San Francisco")
        XCTAssertEqual(PlaceNaming.adminLine(sanFrancisco), "United States · CA · San Francisco")
        // Hong Kong repeats region and city; adjacent duplicates collapse.
        XCTAssertEqual(PlaceNaming.adminLine(hongKong), "中国香港 · Hong Kong · 中環")
        XCTAssertEqual(PlaceNaming.photoTitle(hongKong), "中環 · Hong Kong")
    }

    // MARK: photoTitle

    func testPhotoTitlePrefersPOIAndFallsBackThroughLevels() {
        XCTAssertEqual(PlaceNaming.photoTitle(yiheyuan), "颐和园 · 海淀区")
        XCTAssertEqual(PlaceNaming.photoTitle(chengfulu), "成府路 · 海淀区")
        // District-only placemark escalates to its city.
        let districtOnly = fields(subLocality: "海淀区", locality: "北京市",
                                  administrativeArea: "北京市", country: "中国", countryCode: "CN")
        XCTAssertEqual(PlaceNaming.photoTitle(districtOnly), "海淀区 · 北京市")
        // City whose region repeats it skips the duplicate parent.
        XCTAssertEqual(PlaceNaming.photoTitle(beijingCity), "北京市 · 中国")
        // Country-only placemark.
        XCTAssertEqual(PlaceNaming.photoTitle(fields(country: "印尼", countryCode: "ID")), "印尼")
        // Nothing displayable at all.
        XCTAssertNil(PlaceNaming.photoTitle(fields(countryCode: "CN")))
    }

    // MARK: stopTitles

    func testSameDistrictDayUsesStreetNamesAndPOIsWin() {
        XCTAssertEqual(names(resolved([chengfulu, zhongguancun, yiheyuan])),
                       ["成府路", "中关村大街", "颐和园"])
    }

    func testCrossDistrictDayUsesDistrictNames() {
        XCTAssertEqual(names(resolved([yiheyuan, sanlitun])), ["颐和园", "朝阳区"])
    }

    func testCrossCityDayUsesCityNames() {
        XCTAssertEqual(names(resolved([beijingCity, shanghaiCity])), ["北京市", "上海市"])
    }

    func testCrossCityJapaneseDayFallsBackFromMissingCityToWard() {
        // 東京 wards have no city name; the day still reads 涋谷区 rather than
        // jumping to 東京都, while 横浜 keeps its city level.
        XCTAssertEqual(names(resolved([shibuya, asakusa, yokohama])),
                       ["渋谷区", "浅草寺", "横浜市"])
    }

    func testSingleWardDayUsesNeighborhoodNames() {
        XCTAssertEqual(names(resolved([shibuya, ebisu])), ["道玄坂", "恵比寿"])
    }

    func testStreetlessStopFallsBackToItsDistrict() {
        let streetless = fields(subLocality: "海淀区", locality: "北京市",
                                administrativeArea: "北京市", country: "中国", countryCode: "CN")
        XCTAssertEqual(names(resolved([chengfulu, streetless])), ["成府路", "海淀区"])
    }

    func testFarAwayStopDoesNotCoarsenTheRestOfTheDay() {
        // Only the cross-city pair drops to city level; the same-district
        // stops keep their street names and so never collapse into one.
        XCTAssertEqual(names(resolved([chengfulu, zhongguancun, shanghaiCity])),
                       ["成府路", "中关村大街", "上海市"])
        XCTAssertEqual(names(resolved([shanghaiCity, chengfulu, zhongguancun])),
                       ["上海市", "北京市", "中关村大街"])
    }

    func testPrecisionComparesAcrossUnresolvedStops() {
        let result = titles([.resolved(chengfulu), .unavailable, .resolved(sanlitun)])
        XCTAssertEqual(result, [.title("海淀区"), .unavailable, .title("朝阳区")])
    }

    func testMixedResolutionStatesPassThrough() {
        let result = titles([.resolved(chengfulu), .loading, .unavailable])
        XCTAssertEqual(result, [.title("成府路"), .loading, .unavailable])
    }

    func testUnavailableOnlyDayStaysUnavailable() {
        XCTAssertEqual(titles([.unavailable, .unavailable]),
                       [.unavailable, .unavailable])
    }

    // MARK: Geometry

    func testRepresentativeCoordinateIsARealMemberClosestToCentroid() {
        XCTAssertNil(PlaceNaming.representativeCoordinate(of: []))
        let single: [(latitude: Double, longitude: Double)] = [(39.99, 116.32)]
        XCTAssertEqual(PlaceNaming.representativeCoordinate(of: single)?.latitude ?? 0, 39.99, accuracy: 1e-12)

        // Centroid sits at (40.00, 116.3233); the third point is nearest.
        let points: [(latitude: Double, longitude: Double)] = [
            (39.99, 116.32), (40.01, 116.32), (40.00, 116.33)
        ]
        let representative = PlaceNaming.representativeCoordinate(of: points)
        XCTAssertEqual(representative?.latitude ?? 0, 40.00, accuracy: 1e-12)
        XCTAssertEqual(representative?.longitude ?? 0, 116.33, accuracy: 1e-12)
    }

    func testHaversineDistanceSanity() {
        XCTAssertEqual(PlaceNaming.haversineMeters(lat1: 39.9, lon1: 116.3, lat2: 39.9, lon2: 116.3), 0, accuracy: 0.001)
        // 0.001° of longitude at the equator ≈ 111 m.
        let meters = PlaceNaming.haversineMeters(lat1: 0, lon1: 0, lat2: 0, lon2: 0.001)
        XCTAssertGreaterThan(meters, 100)
        XCTAssertLessThan(meters, 125)
    }

    // MARK: Cache / retry policy

    func testNearestCacheIndexReusesWithinFiftyMeters() {
        let entries: [(latitude: Double, longitude: Double)] = [
            (39.9000, 116.3000), (31.2000, 121.4000)
        ]
        // ~11 m from the first entry.
        XCTAssertEqual(PlaceNaming.nearestCacheIndex(latitude: 39.9001, longitude: 116.3000,
                                                    entries: entries, maxMeters: 50), 0)
        // ~555 m: outside the reuse radius.
        XCTAssertNil(PlaceNaming.nearestCacheIndex(latitude: 39.9050, longitude: 116.3000,
                                                   entries: entries, maxMeters: 50))
        // An empty cache never hits.
        XCTAssertNil(PlaceNaming.nearestCacheIndex(latitude: 0, longitude: 0,
                                                   entries: [], maxMeters: 50))
    }

    func testRetryDelayBacksOffThenGivesUp() {
        XCTAssertEqual(PlaceNaming.retryDelay(afterAttempt: 1), 2)
        XCTAssertEqual(PlaceNaming.retryDelay(afterAttempt: 2), 8)
        XCTAssertEqual(PlaceNaming.retryDelay(afterAttempt: 3), 30)
        XCTAssertNil(PlaceNaming.retryDelay(afterAttempt: 4))
        XCTAssertNil(PlaceNaming.retryDelay(afterAttempt: 5))
        XCTAssertEqual(PlaceNaming.maxGeocodeAttempts, 4)
    }

    func testNoResultStaysFreshForOneWeek() {
        let now = Date()
        XCTAssertTrue(PlaceNaming.noResultIsFresh(savedAt: now, now: now))
        XCTAssertTrue(PlaceNaming.noResultIsFresh(savedAt: now.addingTimeInterval(-6 * 24 * 3600), now: now))
        XCTAssertFalse(PlaceNaming.noResultIsFresh(savedAt: now.addingTimeInterval(-8 * 24 * 3600), now: now))
    }
}
