import Foundation
import CoreGraphics

nonisolated enum PlaceCardStyle: String, CaseIterable, Identifiable {
    case solid, diffuse, glowEdge

    static let storageKey = "OneDay.placeCardStyle"
    var id: Self { self }
    var label: String {
        switch self {
        case .solid: "纯色"
        case .diffuse: "弥散渐变"
        case .glowEdge: "柔边"
        }
    }

    init(savedValue: String?) {
        self = savedValue.flatMap(Self.init(rawValue:)) ?? .solid
    }
}

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
        let hash = Self.stableHash(stopID)
        let index = Int(hash % UInt64(Self.palette.count))
        paletteIndex = index == previousPaletteIndex ? (index + 1) % Self.palette.count : index
    }

    static func identifier(for stopID: String) -> String { "place-card:\(stopID)" }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }

    struct Pastel: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        /// Scaling distance from white preserves the card's single hue.
        func tinted(strength: Double) -> Pastel {
            Pastel(red: 1 - (1 - red) * strength,
                   green: 1 - (1 - green) * strength,
                   blue: 1 - (1 - blue) * strength)
        }
    }

    struct DiffuseGradient: Equatable {
        struct Blob: Equatable {
            /// Center and size are fractions of the card; rotation is in degrees.
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            let rotation: Double
            let color: Pastel
            let opacity: Double
        }
        let base: Pastel
        let blobs: [Blob]
        var colors: [Pastel] { [base] + blobs.map(\.color) }
    }

    /// A pale tint of the card's hue with one saturated glow near the middle,
    /// softened by a broader mid-tone halo so the falloff has no visible edge.
    /// Seeded randomness keeps the composition stable while a stop is geocoded.
    var diffuseGradient: DiffuseGradient {
        var random = GradientRandom(seed: Self.stableHash(stopID))
        let deepest = maximumStrength
        let base = color.tinted(strength: random.value(in: 0.9...1.1))
        let halo = color.tinted(strength: deepest * random.value(in: 0.6...0.7))
        let core = color.tinted(strength: deepest * random.value(in: 0.92...1))
        let x = random.value(in: 0.42...0.58), y = random.value(in: 0.42...0.6)
        let blobs: [DiffuseGradient.Blob] = [
            .init(x: x, y: y, width: random.value(in: 0.95...1.1), height: random.value(in: 0.8...0.95),
                  rotation: random.value(in: -20...20), color: halo, opacity: 0.9),
            .init(x: x, y: y, width: random.value(in: 0.55...0.7), height: random.value(in: 0.45...0.6),
                  rotation: random.value(in: -30...30), color: core, opacity: 1)
        ]
        return DiffuseGradient(base: base, blobs: blobs)
    }

    struct EdgeGlow: Equatable {
        let centerTop: Pastel
        let centerBottom: Pastel
        let edge: Pastel
    }

    /// A bright center in the card's own hue, framed by a thick, blurred band
    /// of the same hue at its deepest legible tone.
    var edgeGlow: EdgeGlow {
        var random = GradientRandom(seed: Self.stableHash(stopID) ^ 0xED6E)
        return EdgeGlow(
            centerTop: color.tinted(strength: random.value(in: 0.35...0.5)),
            centerBottom: color.tinted(strength: random.value(in: 0.8...1)),
            edge: color.tinted(strength: maximumStrength))
    }
    /// Deepest tint that keeps every channel at or above 0.44, so dark text stays legible.
    private var maximumStrength: Double {
        let channels = [color.red, color.green, color.blue].filter { $0 < 1 }
        return min(3, channels.map { 0.56 / (1 - $0) }.min() ?? 1)
    }
    private struct GradientRandom {
        var seed: UInt64

        mutating func value(in range: ClosedRange<Double>) -> Double {
            seed &+= 0x9E3779B97F4A7C15
            var value = seed
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            let fraction = Double(value >> 11) / 9_007_199_254_740_992
            return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        }
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
