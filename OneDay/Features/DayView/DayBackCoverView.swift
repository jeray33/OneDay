import SwiftUI

/// Full-screen back cover: a date-feel caption, an editorial day summary, and
/// the day navigation footer (prev / next / reroll) migrated from the magazine page.
struct DayBackCoverView: View {
    var model: DayViewModel
    var prevDate: Date?
    var nextDate: Date?
    var onPrevDay: (() -> Void)?
    var onNextDay: (() -> Void)?
    var onReroll: () -> Void
    var onClose: () -> Void
    var navLoading: Bool

    var body: some View {
        ZStack {
            model.backCoverBackgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                footer
                    .padding(.bottom, 50)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, model.backCoverColorScheme)

            // Close button top-right (migrated from the magazine top overlay).
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, topSafeAreaInset() + 6)
                }
                Spacer()
            }
            .environment(\.colorScheme, model.backCoverColorScheme)
        }
        .ignoresSafeArea()
    }

    // MARK: Footer (navigation)

    private var footer: some View {
        VStack(spacing: 22) {
            HStack {
                Button { onPrevDay?() } label: {
                    Text(prevDate.map { "← \(Self.navDateText($0))" } ?? "← 无上一次")
                        .font(Theme.serif(16, weight: .medium))
                        .foregroundStyle(navLoading || prevDate == nil ? Theme.ink.opacity(0.3) : Theme.ink)
                }
                .disabled(navLoading || prevDate == nil)
                Spacer()
                Button { onNextDay?() } label: {
                    Text(nextDate.map { "\(Self.navDateText($0)) →" } ?? "无下一次 →")
                        .font(Theme.serif(16, weight: .medium))
                        .foregroundStyle(navLoading || nextDate == nil ? Theme.ink.opacity(0.3) : Theme.ink)
                }
                .disabled(navLoading || nextDate == nil)
            }
            .overlay {
                if navLoading {
                    ProgressView().scaleEffect(0.7).tint(Theme.ink)
                }
            }

            Rectangle().fill(Theme.ink.opacity(0.15)).frame(width: 50, height: 1)
            Button(action: onReroll) {
                Label("再来一天", systemImage: "shuffle")
                    .font(Theme.serif(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: 52)
                    .background(Capsule().fill(Theme.ink))
            }
            Text("摇一摇，换一天")
                .font(Theme.serif(12))
                .foregroundStyle(.tertiary)
        }
    }

    private static func navDateText(_ date: Date) -> String {
        let c = DateText.components(date)
        return "\(c.year).\(c.month).\(c.day)"
    }
}
