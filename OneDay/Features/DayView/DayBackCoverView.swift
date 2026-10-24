import SwiftUI

/// Full-screen, scrollable back cover showing photos from this date in past years.
struct DayBackCoverView: View {
    var model: DayViewModel
    var entries: [TodayInHistoryEntry]
    var isLoading: Bool
    var onSelectHistoryDay: ((Date) -> Void)? = nil
    var scrollEdgesBinding: Binding<ContentScrollEdges>? = nil
    var scrollDisabled = false

    private let horizontalPadding: CGFloat = 20
    private let photoSpacing: CGFloat = 12
    private let maximumPhotoLongSide: CGFloat = 88
    private let ratioRange = (CGFloat(9) / 20)...(CGFloat(16) / 9)
    private let yearColumnWidth: CGFloat = 64
    private let yearPlaceSpacing: CGFloat = 0
    private let placeMinimumFontSize: CGFloat = 12
    /// Distance from the top safe-area edge to the title block.
    private let titleTopOffset: CGFloat = 82

    @State private var headerTitleVisible = false

    var body: some View {
        GeometryReader { geometry in
            let topInset = topSafeAreaInset()
            ZStack {
                Group {
                    if let gradient = model.backCoverGradient {
                        LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
                    } else {
                        model.backCoverBackgroundColor
                    }
                }
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(DateText.dottedMonthDay(model.date))
                                .font(model.coverDateFont.font(18))
                                .foregroundStyle(Theme.ink.opacity(0.7))
                            Text("往年今日")
                                .font(model.coverDateFont.font(46))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                        }
                        .padding(.bottom, 64)

                        historyContent(availableWidth: geometry.size.width - horizontalPadding * 2)

                        Color.clear.frame(height: 1)
                    }
                    .padding(.horizontal, horizontalPadding)
                    // The header bar already insets the content by its height.
                    .padding(.top, max(0, topInset + titleTopOffset - DayPageHeader.height(topInset: topInset)))
                    .padding(.bottom, 160)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(scrollDisabled)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > DayPageHeader.titleRevealOffset
                } action: { _, scrolled in
                    headerTitleVisible = scrolled
                }
                .onScrollGeometryChange(for: ContentScrollEdges.self) { geometry in
                    // At rest the offset equals minus the top inset (the header bar).
                    let minOffset = -geometry.contentInsets.top
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
                .safeAreaBar(edge: .top, spacing: 0) {
                    DayPageHeader(
                        model: model,
                        title: DateText.dottedMonthDay(model.date),
                        titleVisible: headerTitleVisible,
                        topInset: topInset
                    )
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
            .environment(\.colorScheme, model.backCoverColorScheme)
        }
        .ignoresSafeArea()
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
            Text("往年的今天没有可显示内容")
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

        return PhotoFrameView(
            item: item,
            width: totalWidth,
            border: border,
            shared: item.isFromSharedLibrary,
            ratioRange: ratioRange,
            shadowLevel: model.photoShadow,
            cornerRadius: model.photoCornerRadius.value
        )
    }

    private func photoLongSide(availableWidth: CGFloat, photoCount: Int) -> CGFloat {
        let count = CGFloat(max(photoCount, 1))
        let totalSpacing = photoSpacing * CGFloat(max(photoCount - 1, 0))
        let widestPossible = (availableWidth - totalSpacing) / count
        return min(maximumPhotoLongSide, max(widestPossible - 8, 1))
    }


    private var historySeparatorWidth: CGFloat {
        yearColumnWidth + yearPlaceSpacing + maxThreePhotoRowWidth
    }

    private var maxThreePhotoRowWidth: CGFloat {
        let border = max(3, maximumPhotoLongSide * 0.045) * model.borderWidth.scale
        let singleWidth = maximumPhotoLongSide + border * 2
        return singleWidth * 3 + photoSpacing * 2
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
