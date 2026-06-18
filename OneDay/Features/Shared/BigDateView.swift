import SwiftUI

struct BigDateView: View {
    let date: Date
    var compact: Bool = false

    private var size: CGFloat { compact ? 30 : 52 }

    var body: some View {
        let c = DateText.components(date)
        VStack(spacing: compact ? 2 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: compact ? 5 : 9) {
                segment(String(format: "%04d", c.year))
                slash
                segment(String(format: "%02d", c.month))
                slash
                segment(String(format: "%02d", c.day))
            }
            .font(Theme.serif(size, weight: .bold))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            if !compact {
                Text(DateText.weekday(date))
                    .font(Theme.serif(17, weight: .regular))
                    .tracking(4)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func segment(_ value: String) -> some View {
        Text(verbatim: value)
            .contentTransition(.numericText())
    }

    private var slash: some View {
        Text(verbatim: "/")
            .font(Theme.serif(size * 0.82, weight: .ultraLight))
            .foregroundStyle(Theme.ink.opacity(0.3))
    }
}
