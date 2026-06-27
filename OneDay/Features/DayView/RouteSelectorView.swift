import SwiftUI

/// A horizontal, map-path style selector: ordered dots connected by short
/// segments, each labelled with a place. The active dot follows the day view's
/// scroll position; tapping a stop scrolls to that location's earliest photos.
struct RouteSelectorView: View {
    struct Stop: Identifiable {
        let id: String
        let name: String?
    }

    let stops: [Stop]
    let activeID: String?
    var onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.ink.opacity(0.2))
                                .frame(width: 16, height: 1)
                        }
                        stopButton(stop).id(stop.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .onChange(of: activeID) { _, new in
                guard let new else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.ink.opacity(0.08), lineWidth: 1))
    }

    private func stopButton(_ stop: Stop) -> some View {
        let active = activeID == stop.id
        return Button {
            onSelect(stop.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? Theme.accent : Theme.ink.opacity(0.35))
                    .frame(width: active ? 9 : 8, height: active ? 9 : 8)
                Text(stop.name ?? "定位中…")
                    .font(Theme.serif(12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Theme.ink : Theme.ink.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}
