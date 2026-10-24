import Foundation
import CoreGraphics

nonisolated enum PlaceCardRatio: String, CaseIterable, Identifiable {
    case portrait, square

    static let storageKey = "OneDay.placeCardRatio"
    var id: Self { self }
    var label: String { self == .portrait ? "3:4" : "1:1" }
    var widthToHeight: CGFloat { self == .portrait ? 3.0 / 4 : 1 }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .portrait
    }
}

nonisolated enum PlaceCardFlow: String, CaseIterable, Identifiable {
    case separated, continuous

    static let storageKey = "OneDay.placeCardFlow"
    var id: Self { self }
    var label: String { self == .separated ? "分离" : "连续" }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .separated
    }

    static func isApplicable(
        arrangement: DayGridArrangement, placeEnabled: Bool, form: TitleSegmentationPolicy.Form
    ) -> Bool {
        arrangement == .waterfall && placeEnabled && form == .card
    }
}

/// A grid decoration, never a photo asset. Its identity and color do not depend
/// on asynchronous geocoding or Swift's per-process randomized Hasher.
nonisolated struct PlaceSectionCard: Identifiable, Equatable {
    let stopID: String
    let firstPhotoID: String
    var placeName: String?
    let timeText: String
    let paletteIndex: Int

    var id: String { Self.identifier(for: stopID) }
    var title: String { placeName ?? PlaceNaming.loadingTitle }
    var isLoading: Bool { placeName == nil }
    var color: Pastel { Self.palette[paletteIndex] }

    init(stopID: String, firstPhotoID: String, placeName: String?, timeText: String,
         avoiding previousPaletteIndex: Int? = nil) {
        self.stopID = stopID
        self.firstPhotoID = firstPhotoID
        self.placeName = placeName
        self.timeText = timeText
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stopID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let index = Int(hash % UInt64(Self.palette.count))
        paletteIndex = index == previousPaletteIndex ? (index + 1) % Self.palette.count : index
    }

    static func identifier(for stopID: String) -> String { "place-card:\(stopID)" }

    struct Pastel: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static let palette: [Pastel] = [
        Pastel(red: 0.95, green: 0.90, blue: 0.78),
        Pastel(red: 0.97, green: 0.84, blue: 0.84),
        Pastel(red: 0.83, green: 0.90, blue: 0.96),
        Pastel(red: 0.84, green: 0.92, blue: 0.85),
        Pastel(red: 0.90, green: 0.86, blue: 0.95),
        Pastel(red: 0.97, green: 0.89, blue: 0.80),
        Pastel(red: 0.83, green: 0.93, blue: 0.93),
        Pastel(red: 0.93, green: 0.92, blue: 0.83)
    ]

    struct Sizing {
        let width: CGFloat
        let ratio: PlaceCardRatio
        var height: CGFloat { width / ratio.widthToHeight }
        var inset: CGFloat { min(20, max(5, width * 0.09)) }
        var spacing: CGFloat { min(8, max(3, width * 0.04)) }
        var timeFontSize: CGFloat { min(13, max(8, width * 0.065)) }
        var titleLineLimit: Int { width < 100 ? 2 : 3 }
        var wrapsTime: Bool { width < 100 }

        init(width: CGFloat, ratio: PlaceCardRatio = .portrait) {
            self.width = width.isFinite ? max(1, width) : 1
            self.ratio = ratio
        }

        func titleFontSize(preferred: CGFloat) -> CGFloat {
            min(max(preferred.isFinite ? preferred : 26, 10), max(10, width * 0.18))
        }
    }
}
