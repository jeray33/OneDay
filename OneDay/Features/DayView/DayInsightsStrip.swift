import SwiftUI

/// Day facts under the map, wrapping between entries on narrow screens.
struct DayInsightsStrip: View {
    let insights: DayViewModel.DayInsights
    var friendSharedCount: Int = 0

    private static let stepsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        PlaceTrackFlow(horizontalSpacing: 16, verticalSpacing: 8, maximumItemWidth: .infinity) {
            if let steps = insights.steps {
                let count = Self.stepsFormatter.string(from: NSNumber(value: steps)) ?? "\(steps)"
                item(icon: "figure.walk", text: "\(count) 步")
            }
            if let weather = insights.weather {
                item(icon: weather.symbolName,
                     text: "\(weather.condition) \(Int(weather.highCelsius.rounded()))° / \(Int(weather.lowCelsius.rounded()))°")
            }
            if let mood = insights.moodTitle {
                item(icon: "face.smiling", text: mood)
            }
            if friendSharedCount > 0 {
                item(icon: "person.2", text: "好友 \(friendSharedCount) 项")
            }
        }
        .font(Theme.serif(12))
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func item(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text(text)
        }
    }
}
