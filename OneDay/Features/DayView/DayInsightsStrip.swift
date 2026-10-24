import SwiftUI

/// One-line "day at a glance" strip under the route map: steps, weather,
/// mood. Each entry appears only when its data exists; the caller skips the
/// whole strip when `insights` is nil.
struct DayInsightsStrip: View {
    let insights: DayViewModel.DayInsights

    private static let stepsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        HStack(spacing: 16) {
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
