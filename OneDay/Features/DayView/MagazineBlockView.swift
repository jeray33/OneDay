import SwiftUI

struct MagazineBlockView: View {
    let block: MagazineBlock
    let width: CGFloat
    let namespace: Namespace.ID
    var isFavorite: (PhotoItem) -> Bool
    var onSelect: (PhotoItem) -> Void
    var onAction: (LibraryAction, PhotoItem) -> Void

    var body: some View {
        switch block.template {
        case .hero:    hero
        case .single:  single
        case .duo:     duo
        case .trio:    trio
        case .collage: collage
        case .stack:
            StackedClusterView(items: block.items, width: width, namespace: namespace, onSelect: onSelect)
        case .quote:   quote
        }
    }

    // MARK: Templates

    private var hero: some View {
        let item = block.items[0]
        return tappable(item) {
            PhotoFrameView(item: item, width: width, border: 10,
                           kenBurns: true, favorite: isFavorite(item))
        }
    }

    private var single: some View {
        let item = block.items[0]
        return tappable(item) {
            PhotoFrameView(item: item, width: width, border: 9, favorite: isFavorite(item))
        }
    }

    private var duo: some View {
        let spacing: CGFloat = 12
        let side = (width - spacing) / 2
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(block.items.prefix(2)) { item in
                tappable(item) {
                    PhotoFrameView(item: item, width: side, border: 7, favorite: isFavorite(item))
                }
            }
        }
    }

    private var trio: some View {
        let spacing: CGFloat = 10
        let side = (width - spacing * 2) / 3
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(block.items.prefix(3).enumerated()), id: \.element.id) { index, item in
                tappable(item) {
                    PhotoFrameView(item: item, width: side, border: 5, favorite: isFavorite(item))
                }
                .offset(y: index == 1 ? 14 : 0)
            }
        }
    }

    private var collage: some View {
        let primary = block.items[0]
        let rest = Array(block.items.dropFirst())
        let spacing: CGFloat = 10
        let bigWidth = (width - spacing) * 0.64
        let smallWidth = (width - spacing) * 0.36
        return HStack(alignment: .top, spacing: spacing) {
            tappable(primary) {
                PhotoFrameView(item: primary, width: bigWidth, border: 8, favorite: isFavorite(primary))
                    .rotationEffect(.degrees(-2))
            }
            VStack(spacing: 12) {
                ForEach(Array(rest.prefix(3).enumerated()), id: \.element.id) { index, item in
                    tappable(item) {
                        PhotoFrameView(item: item, width: smallWidth, border: 6, favorite: isFavorite(item))
                            .rotationEffect(.degrees(index.isMultiple(of: 2) ? 2.5 : -1.5))
                    }
                }
            }
            .padding(.top, 18)
        }
    }

    private var quote: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 28, height: 1)
            Text(block.caption ?? "")
                .font(Theme.serif(20, weight: .regular))
                .italic()
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 28, height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private func tappable<Content: View>(_ item: PhotoItem, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .matchedTransitionSource(id: item.id, in: namespace)
            .onTapGesture { onSelect(item) }
            .contextMenu {
                Button {
                    onAction(.toggleFavorite, item)
                } label: {
                    Label(isFavorite(item) ? "取消收藏" : "收藏",
                          systemImage: isFavorite(item) ? "heart.slash" : "heart")
                }
                Button {
                    onAction(.pickAlbum, item)
                } label: {
                    Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
                }
                Button(role: .destructive) {
                    onAction(.delete, item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
    }
}
