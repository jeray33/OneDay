import SwiftUI

struct MagazineBlockView: View {
    let block: MagazineBlock
    let width: CGFloat
    let namespace: Namespace.ID
    var config: LayoutConfig = .make(itemCount: 15)  // fallback: standard density
    var frameColor: (PhotoItem) -> Color = { _ in Theme.frame }
    var isFavorite: (PhotoItem) -> Bool
    var onSelect: (PhotoItem) -> Void
    var onAction: (LibraryAction, PhotoItem) -> Void

    var body: some View {
        switch block.template {
        case .single:  single
        case .duo:     duo
        case .trio:    trio
        case .collage: collage
        case .stack:
            StackedClusterView(items: block.items, width: width, namespace: namespace,
                               onSelect: onSelect,
                               borderScale: config.borderScale,
                               frameColor: frameColor)
        case .quote:   quote
        }
    }

    // MARK: Templates

    /// Scales a template's base border pt value by the user-chosen border width level.
    private func b(_ base: CGFloat) -> CGFloat { max((base * config.borderScale).rounded(), 0) }

    private var single: some View {
        let item = block.items[0]
        let photoWidth = (width * config.singleScale).rounded()
        return tappable(item) {
            PhotoFrameView(item: item, width: photoWidth, border: b(9),
                           favorite: isFavorite(item), borderColor: frameColor(item))
        }
        .frame(maxWidth: .infinity, alignment: singleAlignment)
    }

    /// Deterministic left/right alternation based on the block’s stable UUID bytes.
    private var singleAlignment: Alignment {
        block.id.uuid.0 % 2 == 0 ? .leading : .trailing
    }

    private var duo: some View {
        equalHeightRow(items: Array(block.items.prefix(2)), spacing: 12, border: 7)
    }

    private var trio: some View {
        equalHeightRow(items: Array(block.items.prefix(3)), spacing: 10, border: 5)
    }

    /// Equal-height row: all photos share the same image height,
    /// widths are proportional to each photo’s aspect ratio.
    private func equalHeightRow(items: [PhotoItem], spacing: CGFloat, border: CGFloat) -> some View {
        let n         = CGFloat(items.count)
        let ratios    = items.map { min(max($0.aspectRatio, 0.55), 1.85) }
        let sumRatios = ratios.reduce(0, +)
        // Image width available after subtracting gaps and all borders
        let scaledBorder = b(border)
        let availImgW  = width - spacing * (n - 1) - n * 2 * scaledBorder
        // Scale image height so photos fill the row; respect the rowHeight cap
        let imageH     = min(config.rowHeight, availImgW / sumRatios)
        let frameWidths = ratios.map { $0 * imageH + 2 * scaledBorder }

        let stagger = config.staggerFactor
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                tappable(item) {
                    PhotoFrameView(item: item, width: frameWidths[i], border: scaledBorder,
                                   favorite: isFavorite(item), borderColor: frameColor(item))
                }
                // Cascade stagger: base = clipped bottomTrailing phase (0 at identity, no stuck-offset).
                // Each photo i amplifies the movement by (1 + i * stagger), so later photos move
                // more dramatically throughout the entire entry — visible the whole way in.
                .scrollTransition { content, phase in
                    let base = CGFloat(max(0, min(phase.value, 1.0)))
                    let amp  = CGFloat(1.0 + Double(i) * stagger)
                    let v    = min(base * amp, 1.2)  // allow slight overshoot for drama
                    return content
                        .scaleEffect(1 + 0.16 * v)
                        .offset(y: 38 * v)
                }
            }
        }
    }

    private var collage: some View {
        let primary = block.items[0]
        let rest    = Array(block.items.dropFirst().prefix(3))
        let n       = max(rest.count, 1)
        let spacing: CGFloat   = 10
        let bigBorder   = b(8)
        let smallBorder = b(6)
        let topPad: CGFloat = 12

        let bigWidth   = (width - spacing) * 0.64
        let smallWidth = (width - spacing) * 0.36

        // Big photo height derived from its own clamped ratio
        let bigRatio  = min(max(primary.aspectRatio, 0.55), 1.85)
        let bigImgH   = (bigWidth - 2 * bigBorder) / bigRatio
        let bigHeight = bigImgH + 2 * bigBorder

        // Right column: divide (bigHeight − topPad) equally among n items
        let rightAvail  = bigHeight - topPad
        let itemFrameH  = (rightAvail - spacing * CGFloat(n - 1)) / CGFloat(n)
        let rightImgW   = smallWidth - 2 * smallBorder
        let rightImgH   = itemFrameH - 2 * smallBorder
        let lockedRatio = rightImgW / max(rightImgH, 1)

        return HStack(alignment: .top, spacing: spacing) {
            tappable(primary) {
                PhotoFrameView(item: primary, width: bigWidth, border: bigBorder,
                               favorite: isFavorite(primary), borderColor: frameColor(primary))
                    .rotationEffect(.degrees(-1.5))
            }
            VStack(spacing: spacing) {
                ForEach(Array(rest.enumerated()), id: \.element.id) { index, item in
                    let posIdx = index + 1  // big photo is slot 0; small photos start at 1
                    let stagger = config.staggerFactor
                    tappable(item) {
                        PhotoFrameView(item: item, width: smallWidth, border: smallBorder,
                                       favorite: isFavorite(item),
                                       ratioOverride: lockedRatio, borderColor: frameColor(item))
                            .rotationEffect(.degrees(index.isMultiple(of: 2) ? 1.5 : -1.0))
                    }
                    .scrollTransition { content, phase in
                        let base = CGFloat(max(0, min(phase.value, 1.0)))
                        let amp  = CGFloat(1.0 + Double(posIdx) * stagger)
                        let v    = min(base * amp, 1.2)
                        return content
                            .scaleEffect(1 + 0.16 * v)
                            .offset(y: 38 * v)
                    }
                }
            }
            .padding(.top, topPad)
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
