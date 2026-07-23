import SwiftUI

struct HomeView: View {
    var onPickDay: () -> Void
    @State private var appeared = false
    @AppStorage("OneDay.rewindMode") private var rewindModeRaw = RewindMode.flash.rawValue

    private var rewindMode: RewindMode { RewindMode(rawValue: rewindModeRaw) ?? .flash }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Text("今天")
                    .font(Theme.serif(16))
                    .tracking(8)
                    .foregroundStyle(.secondary)
                BigDateView(date: Date())
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer()

            Button(action: onPickDay) {
                Text("时光穿梭")
                    .font(Theme.serif(22, weight: .semibold))
                    .tracking(6)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Theme.ink)
                    )
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 50)
            .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            modeMenu
                .padding(.top, 8)
                .padding(.leading, 16)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
    }

    private var modeMenu: some View {
        Menu {
            Picker("穿梭模式", selection: Binding(
                get: { rewindMode },
                set: { rewindModeRaw = $0.rawValue }
            )) {
                ForEach(RewindMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}
