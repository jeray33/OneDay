import XCTest
@testable import MediaFilter

final class DayPhotoGridSizingTests: XCTestCase {
    private let widths: [CGFloat] = [320, 375, 393, 430, 599, 600, 768, 1_024, 1_366]

    private func sizing(
        _ width: CGFloat, columns: Int, spacing: DayPhotoSideSpacing,
        gap: CGFloat? = nil
    ) -> DayPhotoGridSizing {
        DayPhotoGridSizing(viewportWidth: width, columnCount: columns,
                           horizontalSpacing: gap, sideSpacing: spacing)
    }

    func testMissingAndInvalidPreferencesKeepTheOriginalMaximum() {
        for value in [nil, "", "invalid", "aligned", "waterfall"] as [String?] {
            XCTAssertEqual(DayPhotoSideSpacing(savedValue: value), .max)
        }
        XCTAssertEqual(DayPhotoSideSpacing.allCases, [.none, .small, .medium, .large, .max])
        for option in DayPhotoSideSpacing.allCases {
            XCTAssertEqual(DayPhotoSideSpacing(savedValue: option.rawValue), option)
        }
    }

    func testMaximumExactlyMatchesLegacyCellWidthsForAllColumnsAndSpacingOptions() {
        let gaps: [CGFloat?] = [nil, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40]
        for width in widths {
            for columns in 1...6 {
                for gap in gaps {
                    let innerInset: CGFloat = width - 40 >= 560 ? 20 : 8
                    let horizontal = gap ?? (columns <= 3 ? 16 : columns == 4 ? 14 : 12)
                    let oldAvailable = max(width - 40 - innerInset * 2, 1)
                    let oldCell = max(
                        (oldAvailable - horizontal * CGFloat(columns - 1)) / CGFloat(columns), 1
                    )
                    let expected = columns == 1 ? oldCell * 0.78 : oldCell
                    let result = sizing(width, columns: columns, spacing: .max, gap: gap)
                    XCTAssertEqual(result.cellWidth, expected, accuracy: 0.000_001)
                    if columns > 1 {
                        XCTAssertEqual(result.sideInset, 20 + innerInset)
                    }
                }
            }
        }
    }

    func testEachSmallerOptionReducesInsetAndIncreasesPhotoWidth() {
        for width in widths {
            for columns in 1...6 {
                var previousInset: CGFloat = -1
                var previousCell: CGFloat = .greatestFiniteMagnitude
                for option in DayPhotoSideSpacing.allCases {
                    let result = sizing(width, columns: columns, spacing: option)
                    XCTAssertGreaterThan(result.sideInset, previousInset)
                    XCTAssertLessThan(result.cellWidth, previousCell)
                    previousInset = result.sideInset
                    previousCell = result.cellWidth
                }
            }
        }
    }

    func testNoSideSpacingLetsSingleColumnReachBothEdges() {
        for width in widths {
            let result = sizing(width, columns: 1, spacing: .none)
            XCTAssertEqual(result.sideInset, 0)
            XCTAssertEqual(result.cellWidth, width)
        }
    }

    func testLabelsShowActualPointInsetsForTheCurrentScreenAndColumns() {
        let labels = DayPhotoSideSpacing.allCases.map {
            sizing(393, columns: 2, spacing: $0).sideInsetLabel
        }
        XCTAssertEqual(labels, ["0 pt", "7 pt", "14 pt", "21 pt", "28 pt"])
        XCTAssertEqual(sizing(393, columns: 1, spacing: .max).sideInsetLabel, "65.1 pt")
        XCTAssertEqual(sizing(768, columns: 3, spacing: .max).sideInsetLabel, "40 pt")
    }

    func testEveryLayoutFillsTheAvailableWidthWithoutOverflow() {
        for width in widths {
            for columns in 1...6 {
                for option in DayPhotoSideSpacing.allCases {
                    for gap: CGFloat? in [nil, 0, 16, 40] {
                        let result = sizing(width, columns: columns, spacing: option, gap: gap)
                        let total = result.sideInset * 2 + result.cellWidth * CGFloat(columns)
                            + result.horizontalSpacing * CGFloat(columns - 1)
                        XCTAssertEqual(total, width, accuracy: 0.000_001)
                        XCTAssertGreaterThan(result.cellWidth, 0)
                    }
                }
            }
        }
    }

    func testSideSpacingDoesNotChangeTheGapBetweenPhotos() {
        for columns in 1...6 {
            for option in DayPhotoSideSpacing.allCases {
                XCTAssertEqual(sizing(393, columns: columns, spacing: option, gap: 24).horizontalSpacing, 24)
                let automatic: CGFloat = columns <= 3 ? 16 : columns == 4 ? 14 : 12
                XCTAssertEqual(sizing(393, columns: columns, spacing: option).horizontalSpacing, automatic)
            }
        }
    }

    func testPreferenceSurvivesMigrationAndDoesNotChangeOtherLayoutSettings() {
        let name = "DayPhotoGridSizingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("waterfall", forKey: DayGridArrangement.storageKey)
        defaults.set(4, forKey: GridColumnPolicy.countKey)
        defaults.set(12, forKey: "OneDay.gridHorizontalSpacing")
        defaults.set(true, forKey: "OneDay.photoCaptions")
        for option in DayPhotoSideSpacing.allCases {
            defaults.set(option.rawValue, forKey: DayPhotoSideSpacing.storageKey)
            DayAppearancePreferences.migrateLegacySettings(in: defaults)
            XCTAssertEqual(
                DayPhotoSideSpacing(savedValue: defaults.string(forKey: DayPhotoSideSpacing.storageKey)),
                option
            )
            XCTAssertEqual(defaults.string(forKey: DayGridArrangement.storageKey), "waterfall")
            XCTAssertEqual(defaults.integer(forKey: GridColumnPolicy.countKey), 4)
            XCTAssertEqual(defaults.integer(forKey: "OneDay.gridHorizontalSpacing"), 12)
            XCTAssertTrue(defaults.bool(forKey: "OneDay.photoCaptions"))
        }
    }

    func testInvalidColumnCountsAreClamped() {
        XCTAssertEqual(sizing(393, columns: 0, spacing: .max).columnCount, 1)
        XCTAssertEqual(sizing(393, columns: 99, spacing: .max).columnCount, 6)
        XCTAssertEqual(sizing(393, columns: 2, spacing: .max, gap: -.infinity).horizontalSpacing, 16)
    }
}
