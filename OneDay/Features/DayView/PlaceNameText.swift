import SwiftUI

/// Native/English primary line with a genuine Chinese alternate, if present.
struct PlaceNameText: View {
    let text: String
    let secondaryFont: Font
    var primaryLineLimit: Int = 1

    var body: some View {
        let lines = PlaceNaming.TitleLines(text)
        VStack(alignment: .leading, spacing: 2) {
            Text(lines.primary).lineLimit(primaryLineLimit)
            if let chinese = lines.chinese {
                Text(chinese)
                    .font(secondaryFont)
                    .lineLimit(1)
                    .opacity(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short route may wrap between stops, never between a name and its translation.
struct PlaceTrackFlow: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6
    var maximumItemWidth: CGFloat = 180

    private func plan(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: min(maximumItemWidth, width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 350)
        let frames = plan(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in plan(subviews, width: max(1, bounds.width)).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}
