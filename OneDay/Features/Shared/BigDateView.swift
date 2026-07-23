import SwiftUI

struct BigDateView: View {
    let date: Date
    var compact: Bool = false
    @AppStorage(CoverDateFont.storageKey) private var coverDateFontRaw = CoverDateFont.impact.rawValue

    private var size: CGFloat { compact ? 30 : 58 }
    private var coverDateFont: CoverDateFont {
        CoverDateFont(rawValue: coverDateFontRaw) ?? .impact
    }

    var body: some View {
        VStack(spacing: compact ? 2 : 10) {
            Text(DateText.dottedDate(date))
                .font(coverDateFont.font(size))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())

            if !compact {
                Text(DateText.weekday(date))
                    .font(Theme.serif(17, weight: .regular))
                    .tracking(4)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
