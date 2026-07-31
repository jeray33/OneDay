import SwiftUI

/// Full-screen, scrollable back cover showing photos from this date in past years.
struct DayBackCoverView: View {
    var model: DayViewModel
    var entries: [TodayInHistoryEntry]
    var isLoading: Bool
    var onSelectHistoryDay: ((Date) -> Void)? = nil
    var onClose: () -> Void
    var scrollEdgesBinding: Binding<ContentScrollEdges>? = nil
    var scrollDisabled = false

    private let horizontalPadding: CGFloat = 20
    private let photoSpacing: CGFloat = 12
    private let maximumPhotoLongSide: CGFloat = 88
    private let ratioRange = (CGFloat(9) / 20)...(CGFloat(16) / 9)
    private let yearColumnWidth: CGFloat = 64
    private let yearPlaceSpacing: CGFloat = 0
    private let placeMinimumFontSize: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                model.backCoverBackgroundColor.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(historyTitle)
                            .font(model.coverDateFont.font(46))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .padding(.bottom, 88)

                        historyContent(availableWidth: geometry.size.width - horizontalPadding * 2)

                        Color.clear.frame(height: 1)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topSafeAreaInset() + 82)
                    .padding(.bottom, 160)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(scrollDisabled)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: ContentScrollEdges.self) { geometry in
                    let minOffset = geometry.contentInsets.top
                    let maxOffset = max(
                        minOffset,
                        geometry.contentSize.height
                            + geometry.contentInsets.bottom
                            - geometry.containerSize.height
                    )
                    return ContentScrollEdges(
                        atTop: geometry.contentOffset.y <= minOffset + 1,
                        atBottom: geometry.contentOffset.y >= maxOffset - 1
                    )
                } action: { _, edges in
                    updateScrollEdges(edges)
                }

                DayTopBar(model: model, onClose: onClose, tint: Theme.ink)
            }
            .environment(\.colorScheme, model.backCoverColorScheme)
        }
        .ignoresSafeArea()
        .task(id: frameColorPreparationID) {
            await model.prepareFrameColors(for: entries.flatMap(\.photos))
        }
    }

    @ViewBuilder
    private func historyContent(availableWidth: CGFloat) -> some View {
        if isLoading && entries.isEmpty {
            HStack {
                Spacer()
                ProgressView().tint(Theme.ink)
                Spacer()
            }
            .frame(minHeight: 180)
        } else if entries.isEmpty {
            Text("往年的今天还没有照片")
                .font(Theme.serif(16))
                .foregroundStyle(Theme.ink.opacity(0.62))
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 36) {
                ForEach(entries) { entry in
                    historyRow(entry, availableWidth: availableWidth)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectHistoryDay?(entry.date)
                        }
                }
            }
        }
    }

    private func historyRow(_ entry: TodayInHistoryEntry, availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(Theme.ink.opacity(0.28))
                .frame(width: historySeparatorWidth, height: 0.5)

            HStack(alignment: .top, spacing: 0) {
                Text(String(entry.year))
                    .font(Theme.serif(18, weight: .semibold))
                    .frame(width: yearColumnWidth, alignment: .leading)
                if let placeLine = historyPlaceLine(entry) {
                    Text(placeLine)
                        .font(Theme.serif(placeMinimumFontSize, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
            }

            HStack(alignment: .top, spacing: photoSpacing) {
                ForEach(entry.photos) { item in
                    historyPhoto(
                        item,
                        longSide: photoLongSide(
                            availableWidth: availableWidth,
                            photoCount: entry.photos.count
                        )
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, yearColumnWidth + yearPlaceSpacing)
        }
        .foregroundStyle(Theme.ink)
    }

    private func historyPhoto(_ item: PhotoItem, longSide: CGFloat) -> some View {
        let ratio = min(max(item.aspectRatio, ratioRange.lowerBound), ratioRange.upperBound)
        let border = max(3, longSide * 0.045) * model.borderWidth.scale
        let imageWidth = ratio >= 1 ? longSide : longSide * ratio
        let totalWidth = imageWidth + border * 2
        let polaroidMinimum = min(20, max(5, totalWidth * 0.12))

        return PhotoFrameView(
            item: item,
            width: totalWidth,
            border: border,
            ratioRange: ratioRange,
            borderColor: model.frameColor(for: item),
            polaroid: model.borderStyle.isPolaroid,
            minimumPolaroidBottom: polaroidMinimum,
            shadowLevel: model.photoShadow
        )
    }

    private func photoLongSide(availableWidth: CGFloat, photoCount: Int) -> CGFloat {
        let count = CGFloat(max(photoCount, 1))
        let totalSpacing = photoSpacing * CGFloat(max(photoCount - 1, 0))
        let widestPossible = (availableWidth - totalSpacing) / count
        return min(maximumPhotoLongSide, max(widestPossible - 8, 1))
    }

    private var frameColorPreparationID: String {
        let ids = entries.flatMap(\.photos).map(\.id).joined(separator: "|")
        return "\(model.instanceID.uuidString)|\(model.borderStyle.rawValue)|\(ids)"
    }

    private var historySeparatorWidth: CGFloat {
        yearColumnWidth + yearPlaceSpacing + maxThreePhotoRowWidth
    }

    private var maxThreePhotoRowWidth: CGFloat {
        let border = max(3, maximumPhotoLongSide * 0.045) * model.borderWidth.scale
        let singleWidth = maximumPhotoLongSide + border * 2
        return singleWidth * 3 + photoSpacing * 2
    }

    private var historyTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd"
        return "\(formatter.string(from: model.date)) in History"
    }

    private func historyPlaceLine(_ entry: TodayInHistoryEntry) -> String? {
        let countSuffix = " (\(entry.totalMediaCount))"
        let place = (entry.placeText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if place.isEmpty {
            return entry.totalMediaCount > 0 ? countSuffix : nil
        }
        return place + countSuffix
    }

    private func updateScrollEdges(_ edges: ContentScrollEdges) {
        if let binding = scrollEdgesBinding, binding.wrappedValue != edges {
            binding.wrappedValue = edges
        }
    }
}
