import XCTest
@testable import MediaFilter

final class FeaturedMediaPolicyTests: XCTestCase {
    private struct Item {
        let id: Int
        var video = false
        let score: Float?
    }

    private func curated(_ groups: [[Item]], amount: FeaturedMediaAmount = .balanced) -> [Int] {
        FeaturedMediaPolicy.curatedItems(in: groups, amount: amount, isVideo: \.video, score: \.score).map(\.id)
    }

    func testOnlyBestScoredItemFromEachGroupIsSelected() {
        let scores: [String: Float] = ["photo-a": 0.2, "photo-b": 0.8, "video-a": 0.4, "video-b": 0.7]
        let result = FeaturedMediaPolicy.bestItems(
            in: [["photo-a", "photo-b"], ["video-a", "video-b"], ["not-scored"]]) { scores[$0] }
        XCTAssertEqual(result, ["photo-b", "video-b"])
    }

    func testQualityNotRecencyWinsAndSingletonsRemainEligible() {
        let scores: [String: Float] = ["older": 0.8, "newer": 0.1, "single": -0.2]
        let result = FeaturedMediaPolicy.bestItems(in: [["older", "newer"], ["single"]]) { scores[$0] }
        XCTAssertEqual(result, ["older", "single"])
    }

    func testUnknownAndNonfiniteScoresNeverBecomeFeatured() {
        let scores: [String: Float] = ["nan": .nan, "infinite": .infinity, "negative-infinite": -.infinity]
        let result = FeaturedMediaPolicy.bestItems(in: [["unknown"], ["nan", "infinite", "negative-infinite"]]) {
            scores[$0]
        }
        XCTAssertTrue(result.isEmpty)
    }

    func testTiesPreserveStableSourceOrderAndGroupsPreserveTheirOrder() {
        let result = FeaturedMediaPolicy.bestItems(in: [["a", "b"], ["c", "d"], []]) { _ in 0.5 }
        XCTAssertEqual(result, ["a", "c"])
    }

    func testFeaturedPreferenceIsEnabledInitiallyAndPersistsOff() throws {
        let suite = "FeaturedMediaPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(FeaturedMediaPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: FeaturedMediaPolicy.enabledKey)
        XCTAssertFalse(FeaturedMediaPolicy.isEnabled(defaults: defaults))
        defaults.set(true, forKey: FeaturedMediaPolicy.enabledKey)
        XCTAssertTrue(FeaturedMediaPolicy.isEnabled(defaults: defaults))
    }

    func testAmountDefaultsToBalancedAndPersistsAcrossReloads() throws {
        let suite = "FeaturedMediaAmountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FeaturedMediaAmount.saved(defaults: defaults), .balanced)
        for amount in FeaturedMediaAmount.allCases {
            amount.save(to: defaults)
            XCTAssertEqual(FeaturedMediaAmount.saved(defaults: defaults), amount)
        }
        defaults.set(false, forKey: FeaturedMediaPolicy.enabledKey)
        XCTAssertEqual(FeaturedMediaAmount.saved(defaults: defaults), .generous)
        for invalid: Any in ["invalid", -1, 20.5, 50, false] {
            defaults.set(invalid, forKey: FeaturedMediaAmount.storageKey)
            XCTAssertEqual(FeaturedMediaAmount.saved(defaults: defaults), .balanced)
        }
    }

    func testCountsRoundUpWithoutInventingEmptyCandidates() {
        for amount in FeaturedMediaAmount.allCases {
            XCTAssertEqual(amount.count(from: 0), 0)
            XCTAssertEqual(amount.count(from: -1), 0)
            XCTAssertEqual(amount.count(from: 1), 1)
            for total in 1...250 {
                XCTAssertEqual(amount.count(from: total), (total * amount.rawValue + 99) / 100)
            }
        }
        XCTAssertEqual(FeaturedMediaAmount.strict.count(from: 10), 2)
        XCTAssertEqual(FeaturedMediaAmount.balanced.count(from: 10), 4)
        XCTAssertEqual(FeaturedMediaAmount.generous.count(from: 10), 6)
    }

    func testRatioIsAppliedAfterChoosingGroupRepresentatives() {
        let groups = (0..<10).map { group in
            (0..<3).map { offset in
                let id = group * 3 + offset
                return Item(id: id, score: Float(id))
            }
        }
        XCTAssertEqual(curated(groups), [20, 23, 26, 29])
        XCTAssertEqual(curated(groups, amount: .strict), [26, 29])
        XCTAssertEqual(curated(groups, amount: .generous), [14, 17, 20, 23, 26, 29])
    }

    func testPhotosAndVideosHaveIndependentQuotas() {
        let photos = (0..<10).map { [Item(id: $0, score: Float($0) + 10)] }
        let videos = (0..<4).map { [Item(id: 100 + $0, video: true, score: Float($0) / 10)] }
        XCTAssertEqual(curated(photos + videos), [6, 7, 8, 9, 102, 103])
    }

    func testSelectedItemsKeepChronologicalSourceOrderNotScoreOrder() {
        let items = [Item(id: 8, score: 0.8), Item(id: 1, score: 0.1), Item(id: 9, score: 0.9),
                     Item(id: 7, score: 0.7), Item(id: 2, score: 0.2)]
        XCTAssertEqual(curated(items.map { [$0] }), [8, 9])
    }

    func testUnknownAndNonfiniteScoresAreExcludedFromQuotaDenominator() {
        let items = [Item(id: 0, score: nil), Item(id: 1, score: .nan), Item(id: 2, score: .infinity),
                     Item(id: 3, score: 0.1), Item(id: 4, score: 0.8), Item(id: 5, score: 0.9)]
        XCTAssertEqual(curated(items.map { [$0] }), [4, 5])
        XCTAssertTrue(curated([[Item(id: 0, score: nil)]]).isEmpty)
        XCTAssertTrue(curated([]).isEmpty)
    }

    func testEqualScoresHaveDeterministicStableMembership() {
        let groups = (0..<5).map { [Item(id: $0, score: 0.5)] }
        XCTAssertEqual(curated(groups), [0, 1])
    }

    func testLooserAmountsIncludeAllStricterSelections() {
        let groups = (0..<20).map { [Item(id: $0, video: $0.isMultiple(of: 2), score: Float($0))] }
        let strict = Set(curated(groups, amount: .strict))
        let balanced = Set(curated(groups))
        let generous = Set(curated(groups, amount: .generous))
        XCTAssertTrue(strict.isSubset(of: balanced))
        XCTAssertTrue(balanced.isSubset(of: generous))
    }
}
