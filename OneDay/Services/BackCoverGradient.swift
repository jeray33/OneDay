/// The back cover's fixed immersive gradient, derived from the hero photo.
nonisolated enum BackCoverGradient {
    struct Stop: Equatable {
        var hue: Double
        var saturation: Double
        var brightness: Double
        var location: Double
    }

    /// Without a photo hue, use neutral graphite. Brightness stays low so
    /// the back cover's fixed light foreground keeps its contrast.
    static func stops(hue: Double?, saturation: Double) -> [Stop] {
        guard let hue, hue.isFinite else {
            return [Stop(hue: 0, saturation: 0, brightness: 0.24, location: 0),
                    Stop(hue: 0, saturation: 0, brightness: 0.12, location: 0.5),
                    Stop(hue: 0, saturation: 0, brightness: 0.04, location: 1)]
        }
        let h = hue - hue.rounded(.down)
        let s = saturation.isFinite ? min(max(saturation, 0.35), 0.6) : 0.35
        return [Stop(hue: h, saturation: s, brightness: 0.32, location: 0),
                Stop(hue: h, saturation: s * 0.9, brightness: 0.15, location: 0.5),
                Stop(hue: h, saturation: s * 0.7, brightness: 0.05, location: 1)]
    }
}
