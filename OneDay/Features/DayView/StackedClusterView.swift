import SwiftUI

/// Similar/burst photos shown as a tap-to-fan deck.
struct StackedClusterView: View {
    let items: [PhotoItem]
    var width: CGFloat
    var namespace: Namespace.ID
    var onSelect: (PhotoItem) -> Void

    @State private var expanded = false

    private var cardRatio: CGFloat {
        min(max(items.first?.aspectRatio ?? 0.8, 0.55), 1.85)
    }

    private var cardSize: CGSize {
        let w = min(width * 0.62, 280)
        return CGSize(width: w, height: (w / cardRatio).rounded())
    }

    var body: some View {
        VStack(spacing: 10) {
            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(items) { item in
                            framed(item)
                                .onTapGesture { onSelect(item) }
                        }
                    }
                    .padding(.horizontal, (width - cardSize.width) / 2)
                }
            } else {
                deck
            }
            Label("\(items.count) 张相似", systemImage: expanded ? "square.stack" : "square.stack.3d.up")
                .font(Theme.serif(13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .onTapGesture {
            if !expanded {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { expanded = true }
            }
        }
    }

    private var deck: some View {
        ZStack {
            ForEach(Array(items.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                framed(item)
                    .rotationEffect(.degrees(Double(index) * 3 - 3))
                    .offset(x: CGFloat(index) * 6, y: CGFloat(index) * 6)
                    .zIndex(Double(items.count - index))
            }
        }
        .frame(height: cardSize.height + 18)
    }

    private func framed(_ item: PhotoItem) -> some View {
        PhotoFrameView(item: item, width: cardSize.width, border: 7, ratioOverride: cardRatio)
            .matchedTransitionSource(id: item.id, in: namespace)
    }
}
