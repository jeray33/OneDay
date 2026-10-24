import SwiftUI

extension BackCoverGradient {
    /// Shared rendering for the back cover and each preview photo.
    static func gradient(hue: Double? = nil, saturation: Double = 0) -> Gradient {
        Gradient(stops: stops(hue: hue, saturation: saturation).map {
            .init(color: Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness),
                  location: $0.location)
        })
    }
}
