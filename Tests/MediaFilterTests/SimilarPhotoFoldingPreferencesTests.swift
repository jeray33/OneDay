import XCTest
@testable import MediaFilter

final class SimilarPhotoFoldingPreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "SimilarPhotoFoldingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    func testDefaultAndLegacySelectionsArePreserved() {
        XCTAssertEqual(SimilarPhotoFoldingPreferences(defaults: defaults).level, .nearDuplicate)
        for level in [SimilarPhotoFolding.off, .nearDuplicate, .sameScene] {
            defaults.set(level.rawValue, forKey: SimilarPhotoFolding.storageKey)
            let preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
            XCTAssertEqual(preferences.level, level)
            XCTAssertEqual(preferences.isEnabled, level != .off)
        }
    }

    func testPresetValuesAndParameterOptions() {
        XCTAssertEqual(SimilarPhotoFolding.nearDuplicate.parameters, .init(threshold: 0.28, window: 30))
        XCTAssertEqual(SimilarPhotoFolding.sameScene.parameters, .init(threshold: 0.48, window: 120))
        XCTAssertEqual(SimilarPhotoFolding.loose.parameters, .init(threshold: 0.60, window: 300))
        XCTAssertEqual(SimilarPhotoFolding.veryLoose.parameters, .init(threshold: 0.72, window: 600))
        XCTAssertEqual(SimilarPhotoFolding.enabledCases, [.nearDuplicate, .sameScene, .loose, .veryLoose, .custom])
        let options = SimilarPhotoFoldingParameters.thresholdOptions
        XCTAssertEqual(options.count, 31)
        XCTAssertEqual(options.first, 0.20)
        XCTAssertEqual(options.last, 0.80)
        for pair in zip(options, options.dropFirst()) {
            XCTAssertEqual(pair.1 - pair.0, 0.02, accuracy: 0.000001)
        }
        XCTAssertEqual(SimilarPhotoFoldingParameters.windowOptions, [30, 60, 120, 300, 600])
    }

    func testDisablingAndRelaunchingRestoresLastPreset() {
        var preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
        preferences.select(.veryLoose)
        preferences.isEnabled = false
        preferences.save(to: defaults)
        var restored = SimilarPhotoFoldingPreferences(defaults: defaults)
        XCTAssertFalse(restored.isEnabled)
        restored.isEnabled = true
        XCTAssertEqual(restored.level, .veryLoose)
        XCTAssertEqual(restored.parameters, .init(threshold: 0.72, window: 600))
    }

    func testEditingOneParameterPreservesTheOtherAndSelectsCustom() {
        var preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
        preferences.select(.sameScene)
        preferences.setThreshold(0.64)
        XCTAssertEqual(preferences.level, .custom)
        XCTAssertEqual(preferences.parameters, .init(threshold: 0.64, window: 120))
        preferences.select(.veryLoose)
        preferences.setWindow(60)
        XCTAssertEqual(preferences.level, .custom)
        XCTAssertEqual(preferences.parameters, .init(threshold: 0.72, window: 60))
    }

    func testCustomValuesSurvivePresetChangesDisablingAndRelaunch() {
        var preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
        preferences.setThreshold(0.66)
        preferences.setWindow(600)
        preferences.select(.nearDuplicate)
        preferences.select(.custom)
        XCTAssertEqual(preferences.parameters, .init(threshold: 0.66, window: 600))
        preferences.isEnabled = false
        preferences.save(to: defaults)
        var restored = SimilarPhotoFoldingPreferences(defaults: defaults)
        restored.isEnabled = true
        XCTAssertEqual(restored.level, .custom)
        XCTAssertEqual(restored.parameters, .init(threshold: 0.66, window: 600))
    }

    func testInvalidSavedValuesFallBackSafely() {
        defaults.set("invalid", forKey: SimilarPhotoFolding.storageKey)
        defaults.set("off", forKey: SimilarPhotoFoldingPreferences.lastEnabledKey)
        defaults.set("invalid", forKey: SimilarPhotoFoldingPreferences.thresholdKey)
        defaults.set(-20, forKey: SimilarPhotoFoldingPreferences.windowKey)
        let preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
        XCTAssertEqual(preferences.level, .nearDuplicate)
        XCTAssertEqual(preferences.lastEnabledLevel, .nearDuplicate)
        XCTAssertEqual(preferences.customParameters, .init(threshold: 0.60, window: 300))
    }

    func testThresholdIsClampedAndSnappedToAvailableSteps() {
        XCTAssertEqual(SimilarPhotoFoldingParameters(threshold: 0.10).threshold, 0.20)
        XCTAssertEqual(SimilarPhotoFoldingParameters(threshold: 0.95).threshold, 0.80)
        XCTAssertEqual(SimilarPhotoFoldingParameters(threshold: 0.511).threshold, 0.52)
        XCTAssertEqual(SimilarPhotoFoldingParameters(threshold: .nan).threshold, 0.60)
        XCTAssertEqual(SimilarPhotoFoldingParameters(threshold: .infinity).threshold, 0.60)
        XCTAssertEqual(SimilarPhotoFoldingParameters(window: .nan).window, 300)
    }

    func testEverySavedThresholdCanBeSelectedInPicker() {
        var preferences = SimilarPhotoFoldingPreferences(defaults: defaults)
        for value in SimilarPhotoFoldingParameters.thresholdOptions {
            preferences.setThreshold(value)
            preferences.save(to: defaults)
            let restored = SimilarPhotoFoldingPreferences(defaults: defaults)
            XCTAssertEqual(restored.parameters.threshold, value)
        }
    }
}
