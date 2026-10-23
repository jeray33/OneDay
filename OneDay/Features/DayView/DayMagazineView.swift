import Photos
import SwiftUI
import UIKit

struct DayMagazineView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID
    var dateIsSource: Bool
    var contentRevealed: Bool
    var onClose: () -> Void
    var prevDate: Date? = nil
    var nextDate: Date? = nil
    var onPrevDay: (() -> Void)? = nil
    var onNextDay: (() -> Void)? = nil
    var navLoading: Bool = false
    var scrollEdgesBinding: Binding<ContentScrollEdges>? = nil
    var scrollDisabled: Bool = false
    /// Freezes the inner ScrollView while a page flip owns the drag, so the
    /// scroll view cannot rubber-band the photo content away from the fixed
    /// background/chrome (which only follow the flip offset). Distinct from
    /// `scrollDisabled`, which also greys out the media tabs and bottom toolbar.
    var scrollFrozen: Bool = false
    /// Shows the header's own close/settings buttons. Normally false: the
    /// paged stack draws fixed copies above all pages, and the header keeps
    /// invisible stand-ins for layout. True while the photo preview is open,
    /// because the preview must cover the buttons, and only buttons inside
    /// this view sit beneath it.
    var showsTopButtons: Bool = true

    @Namespace private var previewNamespace

    @State private var revealContent = false
    @State private var pinchScale: CGFloat = 1.0
    @State private var pinchBaseline: CGFloat = 1.0
    @State private var editingItem: PhotoItem?

    // Hero transition (self-drawn flight layer). All per-frame flight state now
    // lives in HeroOverlayView, so dragging/flying the preview never
    // re-evaluates this (large) grid body. Only `frameStore` (a reference type
    // that mutates in place without invalidating the body) and the one-shot
    // open request are shared with the overlay.
    @State private var frameStore = HeroFrameStore()
    @State private var heroRequest: PhotoItem?
    @State private var fixedHeaderHeight: CGFloat = 0
    @State private var headerTitleVisible = false
    /// Cached top safe-area inset. Read once when the status bar is visible,
    /// then reused so that `.statusBarHidden()` during the hero session cannot
    /// change the fixed header's height and shift the grid.
    @State private var stableTopInset: CGFloat = 0
    // Bottom quick-scroll toolbar. `scrubber` is a reference type so
    // per-frame scroll updates never re-evaluate this grid body.
    @State private var scrubber = DayScrubberState()
    @State private var scrollPosition = ScrollPosition()
    @State private var bottomBarHeight: CGFloat = 0

    private var shouldRevealContent: Bool {
        contentRevealed && revealContent
    }

    /// Uses the cached inset when available, falling back to a live read.
    private var stableTopInsetValue: CGFloat {
        stableTopInset > 0 ? stableTopInset : topSafeAreaInset()
    }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = geo.size.width - 40
            ScrollViewReader { proxy in
              ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 0)
                            .id("scroll_top")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ContentTopKey.self,
                                        value: geo.frame(in: .named("dayScroll")).minY
                                    )
                                }
                            )

                        if model.showsMediaTabs {
                            mediaTabs
                        }
                        Color.clear.frame(height: model.showsPhotoMap ? 0 : 24)

                        if model.allItems.isEmpty {
                            Text("这一天没有可显示内容")
                                .font(Theme.serif(17))
                                .foregroundStyle(Theme.ink.opacity(0.65))
                                .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                                .padding(.horizontal, 20)
                                .padding(.top, 40)
                        }

                        if !model.allItems.isEmpty && model.showsPhotoMap {
                            DayRouteMapBanner(locations: model.routeLocations,
                                              stopCoordinates: model.routeStopCoordinates,
                                              stopNames: model.routeStopDisplayNames,
                                              date: model.date,
                                              dateFont: model.coverDateFont.font(SectionTitleSize.small.size),
                                              blendMode: model.mapBlendMode,
                                              backgroundColor: model.pageBackgroundColor,
                                              isDarkPage: model.pageColorScheme == .dark)
                                .frame(width: geo.size.width)
                        }

                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { sIdx, section in
                            sectionView(section, index: sIdx, contentWidth: contentWidth)
                                .padding(.top, sectionTopSpacing(for: sIdx))
                        }

                        VStack(spacing: 0) {
                            if model.showTextDayNavigation {
                                dayNavigationFooter
                            }
                            backCoverHint
                                .padding(.top, model.showTextDayNavigation ? 0 : 96)
                            Color.clear.frame(height: 1).id("scroll_bottom")
                        }
                    }
                    .coordinateSpace(name: "dayContent")
                    .padding(.bottom, 56)
                    .background {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: ContentScrollBoundsKey.self,
                                value: contentGeometry.frame(in: .named(heroCoordinateSpace))
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(columnPinchGesture)
                }
                .scrollDisabled(scrollDisabled || scrollFrozen || pinchScale != 1.0)
                .scrollIndicators(model.showDayScrollIndicator ? .automatic : .hidden)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    scrubber.updateRawOffset(offset)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > DayPageHeader.titleRevealOffset
                } action: { _, scrolled in
                    headerTitleVisible = scrolled
                }
                .background(model.pageBackgroundColor.ignoresSafeArea())
                .environment(\.colorScheme, model.pageColorScheme)
                .animation(.easeInOut(duration: 0.35), value: model.background)
                // A safe-area bar lets content pass underneath the header.
                // The system progressively blurs that backdrop, not the header.
                .safeAreaBar(edge: .top, spacing: 0) {
                    fixedHeader
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            fixedHeaderHeight = $0
                        }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    if model.showBottomToolbar {
                        DayBottomToolbar(
                            state: scrubber,
                            prevDate: prevDate,
                            nextDate: nextDate,
                            navLoading: navLoading,
                            enabled: bottomToolbarEnabled,
                            showsSectionMarks: model.showScrubberSectionMarks,
                            tickHapticsEnabled: model.scrubberTickHaptics,
                            onPrevDay: { onPrevDay?() },
                            onNextDay: { onNextDay?() },
                            onScrub: { progress, animated in
                                scrub(to: progress, animated: animated)
                            }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            bottomBarHeight = $0
                        }
                        .onDisappear { bottomBarHeight = 0 }
                        .revealFade(shouldRevealContent, delay: 0.5)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .coordinateSpace(name: "dayScroll")
                .onChange(of: model.instanceID) {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("scroll_top") }
                }
                .onChange(of: model.selectedMediaCategory) { _, _ in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("scroll_top", anchor: .top)
                    }
                }
                .onPreferenceChange(ContentScrollBoundsKey.self) { bounds in
                    scrubber.contentBounds = bounds
                    recomputeScrollEdges(contentBounds: bounds, viewportSize: geo.size)
                }
                .onPreferenceChange(ContentTopKey.self) { minY in
                    guard let minY else { return }
                    scrubber.updateContentTop(
                        minY,
                        viewportTop: fixedHeaderHeight,
                        viewportHeight: geo.size.height - fixedHeaderHeight - bottomBarHeight
                    )
                }
                .onPreferenceChange(SectionTopKey.self) { tops in
                    scrubber.updateSectionTops(tops.values.sorted())
                }
                .onChange(of: fixedHeaderHeight) { _, _ in
                    recomputeScrollEdges(contentBounds: scrubber.contentBounds, viewportSize: geo.size)
                }
                .onChange(of: bottomBarHeight) { _, _ in
                    recomputeScrollEdges(contentBounds: scrubber.contentBounds, viewportSize: geo.size)
                }
                .onChange(of: model.previewCurrentID) { _, id in
                    guard model.selected != nil, let id,
                          let blockID = model.blockID(forItemID: id) else { return }
                    // Requirement B: only scroll when the target cell is off
                    // screen. Scrolling a visible cell would kick the cells'
                    // animated `scrollTransition` and make the grid wobble when
                    // it is revealed on close.
                    if let rect = frameStore.cells[id]?.rect,
                       rect.midY >= fixedHeaderHeight, rect.midY <= geo.size.height {
                        return
                    }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(blockID, anchor: .center) }
                }
                .environment(\.colorScheme, model.pageColorScheme)

                HeroOverlayView(model: model,
                                frameStore: frameStore,
                                namespace: previewNamespace,
                                screen: geo.size,
                                request: $heroRequest)
              }
              .coordinateSpace(name: heroCoordinateSpace)
              .onPreferenceChange(HeroCellFrameKey.self) { frameStore.cells = $0 }
            }
        }
        .task(id: model.instanceID) {
            // Cache the top inset while the status bar is visible, before any
            // hero session might hide it. This prevents the ScrollView content
            // from shifting when the status bar toggles during preview open/close.
            stableTopInset = topSafeAreaInset()
            revealContent = false
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.spring(response: 0.82, dampingFraction: 0.90)) {
                revealContent = true
            }
            await model.prepare()
        }
        .sheet(item: albumPickerBinding) { item in
            AlbumPickerSheet(item: item, model: model, onFinish: {})
        }
        .sheet(item: $editingItem) { item in
            CaptionEditorSheet(item: item) { caption in
                Task { await model.updateCaption(caption, for: item) }
            }
        }
        .alert("保存说明失败", isPresented: captionErrorBinding) {
            Button("好") { model.captionErrorMessage = nil }
        } message: {
            Text(model.captionErrorMessage ?? "")
        }
    }

    private var captionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.captionErrorMessage != nil },
            set: { if !$0 { model.captionErrorMessage = nil } }
        )
    }

    // MARK: Day navigation

    private var dayNavigationFooter: some View {
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
        .padding(.horizontal, 28)
        .padding(.top, 96)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity)
        .revealFade(shouldRevealContent, delay: 0.5)
    }

    /// Same style as the tunnel page's bottom hint.
    private var backCoverHint: some View {
        Text("上滑查看历史上的这天")
            .font(Theme.serif(12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .revealFade(shouldRevealContent, delay: 0.5)
    }

    private static func navDateText(_ date: Date) -> String {
        let components = DateText.components(date)
        return "\(components.year).\(components.month).\(components.day)"
    }

    private var selectedBinding: Binding<PhotoItem?> {
        Binding(
            get: { model.selected },
            set: { model.selected = $0 }
        )
    }

    private var columnPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                pinchScale = scale
                let ratio = scale / pinchBaseline
                if ratio < 0.75 {
                    let newCount = min(6, model.gridColumnCount + 1)
                    if newCount != model.gridColumnCount {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            model.gridColumnCount = newCount
                        }
                        pinchBaseline = scale
                    }
                } else if ratio > 1.30 {
                    let newCount = max(1, model.gridColumnCount - 1)
                    if newCount != model.gridColumnCount {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            model.gridColumnCount = newCount
                        }
                        pinchBaseline = scale
                    }
                }
            }
            .onEnded { _ in
                pinchScale = 1.0
                pinchBaseline = 1.0
            }
    }

    private var albumPickerBinding: Binding<PhotoItem?> {
        Binding(
            get: { model.albumPickerItem },
            set: { model.albumPickerItem = $0 }
        )
    }

    // MARK: Top bar

    private var fixedHeader: some View {
        DayPageHeader(
            model: model,
            title: DateText.dottedDate(model.date),
            titleVisible: headerTitleVisible,
            topInset: stableTopInsetValue,
            onClose: onClose,
            showsButtons: showsTopButtons
        )
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    private var mediaTabs: some View {
        HStack(spacing: 0) {
            ForEach(model.availableMediaCategories) { category in
                let isSelected = model.selectedMediaCategory == category
                Button {
                    model.selectMediaCategory(category)
                } label: {
                    Text(category.tabLabel)
                        .font(Theme.serif(15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 1 : 0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Theme.ink.opacity(isSelected ? 1 : 0))
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.selected != nil || scrollDisabled)
                .accessibilityLabel(category.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("day-media-tab-\(category.rawValue)")
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当天内容类别")
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    // MARK: Aligned grid

    @ViewBuilder
    private func alignedGridRow(_ blocks: [MagazineBlock], contentWidth: CGFloat) -> some View {
        let count = min(max(model.gridColumnCount, 1), 6)
        let horizontalInset: CGFloat = contentWidth >= 560 ? 20 : 8
        let horizontalSpacing = model.gridHorizontalSpacing
            ?? alignedGridHorizontalSpacing(for: count)
        let availableWidth = max(contentWidth - horizontalInset * 2, 1)
        let cellWidth = max(
            (availableWidth - horizontalSpacing * CGFloat(count - 1)) / CGFloat(count),
            1
        )
        // 一列时收窄，避免照片过宽
        let finalCellWidth = count == 1 ? cellWidth * 0.78 : cellWidth
        let frameAlignment: Alignment = count == 1 ? .center : .leading
        let entries = blocks.flatMap { block in
            block.items.enumerated().map { index, item in
                AlignedGridEntry(item: item, blockID: block.id, startsBlock: index == 0)
            }
        }

        if model.gridLazyEnabled {
            let columns = Array(
                repeating: GridItem(.fixed(finalCellWidth), spacing: horizontalSpacing, alignment: .top),
                count: count
            )
            LazyVGrid(columns: columns, alignment: .leading, spacing: model.gridVerticalSpacing) {
                ForEach(entries) { entry in
                    if entry.startsBlock {
                        alignedGridCell(entry.item, width: finalCellWidth)
                            .id(entry.blockID)
                    } else {
                        alignedGridCell(entry.item, width: finalCellWidth)
                    }
                }
            }
            .frame(maxWidth: count == 1 ? finalCellWidth : nil)
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        } else {
            let rowCount = (entries.count + count - 1) / count
            VStack(alignment: .leading, spacing: model.gridVerticalSpacing) {
                ForEach(0..<rowCount, id: \.self) { rowIndex in
                    let start = rowIndex * count
                    let end = min(start + count, entries.count)
                    HStack(alignment: .top, spacing: horizontalSpacing) {
                        ForEach(entries[start..<end]) { entry in
                            if entry.startsBlock {
                                alignedGridCell(entry.item, width: finalCellWidth)
                                    .id(entry.blockID)
                            } else {
                                alignedGridCell(entry.item, width: finalCellWidth)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                }
            }
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    private func alignedGridCell(_ item: PhotoItem, width: CGFloat) -> some View {
        let count = min(max(model.gridColumnCount, 1), 6)
        let border = max(
            (alignedGridBorderBase(for: count) * model.borderWidth.scale).rounded(),
            0
        )
        let ratioRange = (CGFloat(9) / 20)...(CGFloat(16) / 9)
        // While a preview is open, apply scroll transitions instantly (no
        // spring) so revealing the grid on close cannot make cells wobble.
        let scrollAnimation = model.selected != nil ? .linear(duration: 0) : model.scrollSpring.animation
        let scrollScale = model.scrollScale.value
        let scrollMovement = model.scrollMovement.value
        let scrollRotation = model.scrollRotation.value
        let scrollOpacity = model.scrollFade.offScreenOpacity
        let scrollBlur = CGFloat(model.scrollBlur.radius)
        let scrollParallax = model.scrollParallax.factor
        let scrollTiltX = CGFloat(model.scrollTiltX.degrees)
        let scrollTiltY = CGFloat(model.scrollTiltY.degrees)
        let scrollTiltDecay = model.scrollTiltDecay.power

        return PhotoFrameView(
            item: item,
            width: width,
            border: border,
            favorite: model.isFavorite(item),
            shared: item.isFromSharedLibrary,
            ratioRange: ratioRange,
            shadowLevel: model.photoShadow,
            showCaption: model.showPhotoCaptions,
            cornerRadius: model.photoCornerRadius.value,
            onEditCaption: { editingItem = $0 }
        )
        .heroCell(id: item.id, hiddenID: heroHiddenID)
        .onTapGesture { heroRequest = item }
        .contextMenu {
            Button {
                Task { await model.perform(.toggleFavorite, on: item) }
            } label: {
                Label(model.isFavorite(item) ? "取消收藏" : "收藏",
                      systemImage: model.isFavorite(item) ? "heart.slash" : "heart")
            }
            .disabled(!item.sharedCapabilities.canFavorite)
            Button {
                Task { await model.perform(.pickAlbum, on: item) }
            } label: {
                Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(!item.sharedCapabilities.canEditAlbums)
            Button(role: .destructive) {
                Task { await model.perform(.delete, on: item) }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!item.sharedCapabilities.canDelete)
        }
        .scrollTransition(.animated(scrollAnimation)) { content, phase in
            let y: CGFloat = phase == .bottomTrailing ? scrollMovement :
                             phase == .topLeading ? -scrollMovement * 0.64 : 0
            return content
                .opacity(phase.isIdentity ? 1 : scrollOpacity)
                .scaleEffect(
                    phase == .topLeading ? (1.0 - scrollScale) :
                    phase == .bottomTrailing ? (1.0 + scrollScale) : 1.0
                )
                .rotationEffect(.degrees(
                    phase == .topLeading ? scrollRotation :
                    phase == .bottomTrailing ? -scrollRotation : 0
                ))
                .offset(y: y)
                .blur(radius: phase == .bottomTrailing ? scrollBlur * CGFloat(phase.value) : 0)
        }
        .scrollTransition(.interactive) { content, phase in
            let parallaxY = CGFloat(-min(0.0, phase.value)) * scrollParallax
            let value = phase.value
            let easedValue = CGFloat(
                (value >= 0 ? 1.0 : -1.0) * pow(abs(value), scrollTiltDecay)
            )
            return content
                .rotation3DEffect(.degrees(easedValue * scrollTiltX),
                                  axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(easedValue * scrollTiltY),
                                  axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .offset(y: parallaxY)
        }
    }

    private func alignedGridHorizontalSpacing(for count: Int) -> CGFloat {
        switch count {
        case 1...3: return 16
        case 4:     return 14
        default:    return 12
        }
    }

    private func alignedGridBorderBase(for count: Int) -> CGFloat {
        switch count {
        case 1: return 9
        case 2: return 7
        case 3: return 5
        case 4: return 4
        case 5: return 3
        default: return 2
        }
    }

    private func updateScrollEdges(_ edges: ContentScrollEdges) {
        if let binding = scrollEdgesBinding, binding.wrappedValue != edges {
            binding.wrappedValue = edges
        }
    }

    /// Recomputes flip edges for the latest content bounds. The viewport
    /// excludes both chrome bars; the bottom bar height must be subtracted
    /// here or content resting under the toolbar would look "at bottom".
    private func recomputeScrollEdges(contentBounds: CGRect?, viewportSize: CGSize) {
        guard let bounds = contentBounds else { return }
        updateScrollEdges(ContentScrollEdges(
            contentBounds: bounds,
            viewportBounds: CGRect(
                x: 0, y: fixedHeaderHeight,
                width: viewportSize.width,
                height: max(0, viewportSize.height - fixedHeaderHeight - bottomBarHeight)
            )
        ))
    }

    /// Whether the bottom toolbar accepts interaction right now.
    private var bottomToolbarEnabled: Bool {
        !scrollDisabled && pinchScale == 1 && model.selected == nil
    }

    /// Jumps the content to a scrubber progress. Targets are derived purely
    /// from offset differences, so they stay correct regardless of the
    /// scroll view's offset convention.
    private func scrub(to progress: CGFloat, animated: Bool) {
        guard bottomToolbarEnabled, scrubber.metrics.isScrollable else { return }
        let target = scrubber.metrics.targetOffset(forProgress: progress)
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                scrollPosition.scrollTo(y: target)
            }
        } else {
            scrollPosition.scrollTo(y: target)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: MagazineSection, index: Int, contentWidth: CGFloat) -> some View {
        let rows = sectionRows(section)
        if !rows.isEmpty {
            let hasHeading = section.placeHeading != nil
                || section.placeHeadingPending
                || section.showsTimeHeading
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(section)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    rowView(row, contentWidth: contentWidth)
                        .padding(.top, rowTopSpacing(index: idx, rows: rows) * (idx == 0 && !hasHeading ? 0.5 : 1))
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .reveal(shouldRevealContent, delay: 0.42 + Double(index) * 0.14)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SectionTopKey.self,
                        value: [section.id.uuidString: geo.frame(in: .named("dayContent")).minY]
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: MagazineSection) -> some View {
        if section.placeHeading != nil || section.placeHeadingPending {
            sectionHeading(section.placeHeading ?? "定位中…",
                           size: model.sectionTitleSize.size,
                           visible: true)
                .opacity(section.placeHeading == nil ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.3), value: section.placeHeading)
        }
        if section.showsTimeHeading && !section.timeHeadingIsNested {
            sectionHeading(
                section.band.englishTitle,
                size: model.sectionTitleSize.size,
                visible: true
            )
        }
    }

    private func sectionHeading(_ title: String, size: CGFloat, visible: Bool) -> some View {
        Text(title)
            .font(model.coverDateFont.font(size))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: title)
    }

    /// Spacing above each section: 64pt with headings and half that when
    /// headings are hidden. A pending place heading already reserves its
    /// heading slot.
    private func sectionTopSpacing(for index: Int) -> CGFloat {
        let section = model.sections[index]
        return section.placeHeading != nil
            || section.placeHeadingPending
            || section.showsTimeHeading ? 64 : 32
    }

    @ViewBuilder
    private func rowView(_ row: SectionRow, contentWidth: CGFloat) -> some View {
        switch row {
        case .label(let text):
            Text(text)
                .font(Theme.serif(13))
                .foregroundStyle(Theme.ink.opacity(0.7))
        case .grid(let blocks):
            alignedGridRow(blocks, contentWidth: contentWidth)
        }
    }

    private func rowTopSpacing(index: Int, rows: [SectionRow]) -> CGFloat {
        let row = rows[index]
        if index == 0 {
            if case .label = row { return 6 }
            return 24
        }
        if case .label = row { return 80 }              // start of a new time segment
        if case .label = rows[index - 1] { return 12 }  // photos tucked under their time label
        return 56
    }

    /// Builds the ordered rows for a section: time-segment labels interleaved
    /// with photo grids. A section spanning ≤ 2h gets one label under the
    /// title; a longer section is split into clock-aligned 2-hour segments,
    /// each labelled above its first photo with that segment's actual span.
    /// Place-only sections keep a single overall range without splitting rows.
    private func sectionRows(_ section: MagazineSection) -> [SectionRow] {
        let blocks = section.blocks
        guard !blocks.isEmpty else { return [] }
        guard section.showsTimeHeading || section.placeHeading != nil else {
            return contentRows(for: blocks)
        }
        let allDated = datedItems(blocks.flatMap(\.items))
        guard let first = allDated.first, let last = allDated.last,
              let firstDate = first.creationDate, let lastDate = last.creationDate else {
            return contentRows(for: blocks)
        }
        if !section.showsTimeHeading || lastDate.timeIntervalSince(firstDate) <= 2 * 3600 {
            return [.label(timeRangeText(first, last))] + contentRows(for: blocks)
        }
        var rows: [SectionRow] = []
        var currentBucket: Date?
        var bucketBlocks: [MagazineBlock] = []
        func flush() {
            guard !bucketBlocks.isEmpty else { return }
            let dated = datedItems(bucketBlocks.flatMap(\.items))
            if let f = dated.first, let l = dated.last {
                rows.append(.label(timeRangeText(f, l)))
            }
            rows.append(contentsOf: contentRows(for: bucketBlocks))
            bucketBlocks.removeAll()
        }
        for block in blocks {
            let t = datedItems(block.items).first ?? first
            let bucket = alignedBucket(t)
            if currentBucket == nil { currentBucket = bucket }
            if bucket != currentBucket { flush(); currentBucket = bucket }
            bucketBlocks.append(block)
        }
        flush()
        return rows
    }

    private func contentRows(for blocks: [MagazineBlock]) -> [SectionRow] {
        [.grid(blocks)]
    }

    /// Items that carry a capture date, oldest first.
    private func datedItems(_ items: [PhotoItem]) -> [PhotoItem] {
        items.filter { $0.creationDate != nil }.sorted { $0.creationDate! < $1.creationDate! }
    }

    /// Rounds a capture down to a clock-aligned even hour (…14:00, 16:00…)
    /// of its local time.
    private func alignedBucket(_ item: PhotoItem) -> Date {
        let date = item.creationDate ?? .distantPast
        var cal = Calendar.current
        cal.timeZone = item.captureTimeZone
        var c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        c.hour = ((c.hour ?? 0) / 2) * 2
        c.minute = 0
        c.second = 0
        return cal.date(from: c) ?? date
    }

    /// Each end reads in its own capture's local zone.
    private func timeRangeText(_ start: PhotoItem, _ end: PhotoItem) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = start.captureTimeZone
        let s = f.string(from: start.creationDate ?? .distantPast)
        f.timeZone = end.captureTimeZone
        let e = f.string(from: end.creationDate ?? .distantPast)
        return s == e ? s : "\(s) - \(e)"
    }

    private var footer: some View {
        // The day navigation footer has moved to the back cover. A small spacer
        // is kept so the bottom sentinel has something to anchor against.
        Color.clear.frame(height: 24)
    }

    // MARK: Hero transition

    /// The grid cell to hide while its photo is presented (empties its slot so
    /// the fly-back lands into a real gap).
    private var heroHiddenID: String? {
        model.selected != nil ? model.previewCurrentID : nil
    }

}

// MARK: - Section rows

/// A rendered row inside a section: a time label or aligned photo grid.
private enum SectionRow {
    case label(String)
    case grid([MagazineBlock])
}

private struct AlignedGridEntry: Identifiable {
    let item: PhotoItem
    let blockID: UUID
    let startsBlock: Bool

    var id: String { item.id }
}

// MARK: - Scroll tracking

private struct ContentScrollBoundsKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

/// Content-top position in the scroll coordinate space, per scroll frame.
private struct ContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Section-top positions in content space (stable while scrolling).
private struct SectionTopKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - View helpers

private extension View {
    func reveal(_ revealed: Bool, delay: Double) -> some View {
        self
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 24)
            .animation(.spring(response: 0.82, dampingFraction: 0.90).delay(revealed ? delay : 0),
                       value: revealed)
    }

    func revealFade(_ revealed: Bool, delay: Double) -> some View {
        self
            .opacity(revealed ? 1 : 0)
            .animation(.easeInOut(duration: 0.55).delay(revealed ? delay : 0),
                       value: revealed)
    }
}
