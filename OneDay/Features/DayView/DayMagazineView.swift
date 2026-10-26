import Photos
import SwiftUI
import UIKit
import os

struct DayMagazineView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID
    var dateIsSource: Bool
    var onClose: () -> Void
    var prevDate: Date? = nil
    var nextDate: Date? = nil
    var onPrevDay: (() -> Void)? = nil
    var onNextDay: (() -> Void)? = nil
    var navLoading: Bool = false
    var showsBackCoverHint: Bool = true
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
    /// Whether the photo cover's date joins the shared date transition.
    var coverDateMatched: Bool = true
    /// Shared across day models by RootView: after the first entrance the
    /// bottom toolbar no longer fades in on day-to-day navigation.
    var chromeRevealed: Binding<Bool>? = nil
    /// Set once the day page card, not the photo cover, lies under the
    /// fixed top buttons.
    var photoCardUnderTopBar: Binding<Bool>? = nil

    @Namespace private var previewNamespace
    @Namespace private var similarPhotoNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coverScroll = PhotoCoverScrollState()
    @State private var scrollPerformance = DayScrollPerformanceProbe()

    @State private var shouldRevealContent = false
    @State private var pinchScale: CGFloat = 1.0
    @State private var pinchBaseline: CGFloat = 1.0

    // Hero transition (self-drawn flight layer). All per-frame flight state now
    // lives in HeroOverlayView, so dragging/flying the preview never
    // re-evaluates this (large) grid body. Only `frameStore` (a reference type
    // that mutates in place without invalidating the body) and the one-shot
    // open request are shared with the overlay.
    @State private var frameStore = HeroFrameStore()
    @State private var gridAnchorTracker = DayGridAnchorTracker()
    @State private var waterfallViewport = WaterfallViewport()
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
    @State private var mediaTabFrames: [DayMediaTab: CGRect] = [:]

    /// Uses the cached inset when available, falling back to a live read.
    private var stableTopInsetValue: CGFloat {
        stableTopInset > 0 ? stableTopInset : topSafeAreaInset()
    }

    var body: some View {
        GeometryReader { geo in
            let gridRevision = gridLayoutRevision(viewportWidth: geo.size.width)
            let coverHeight = (geo.size.height * 2 / 3).rounded()
            let headerHeight = DayPageHeader.height(topInset: stableTopInsetValue)
            // Content starts below the header bar, so the card's rest
            // position is reached by this much leading space.
            let coverSpace = max(0, coverHeight - headerHeight)
            ScrollViewReader { proxy in
              ZStack {
                DayPhotoCoverView(model: model, scroll: coverScroll,
                                  width: geo.size.width, visibleHeight: coverHeight,
                                  travel: coverSpace,
                                  dateNamespace: coverDateMatched ? dateNamespace : nil,
                                  dateIsSource: dateIsSource)
                    .task(id: model.instanceID) { await model.prepareEditorial() }
                PhotoCardBackdrop(scroll: coverScroll, coverHeight: coverHeight,
                                  travel: coverSpace, color: model.pageBackgroundColor)
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

                        Color.clear.frame(height: coverSpace)
                        // Without tabs, the content starts flush with the card.
                        Color.clear.frame(height: model.showsMediaTabs ? Self.cardTopPadding : 0)
                            .id("card_top")

                        if model.showsMediaTabs {
                            mediaTabs
                        }
                        Color.clear.frame(height: model.hasAnyLocation ? 0 : 24)

                        if model.allItems.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                if model.selectedMediaTab == .featured {
                                    if model.isPreparingFeatured {
                                        HStack(spacing: 10) {
                                            ProgressView().tint(Theme.ink)
                                            Text("正在精选本地照片和视频")
                                        }
                                    } else {
                                        Text("暂无可评估的精选内容")
                                    }
                                    Text("先每组择优，再分别保留照片和视频前 \(model.featuredAmount.rawValue)%。未取得本地评分的素材暂不入选，原有内容仍保留。")
                                        .font(.footnote)
                                } else {
                                    Text("这一天没有可显示内容")
                                }
                            }
                            .font(Theme.serif(17))
                            .foregroundStyle(Theme.ink.opacity(0.65))
                            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                            .padding(.horizontal, 20)
                            .padding(.top, 40)
                        }

                        if model.hasAnyLocation {
                            DayRouteMapBanner(locations: model.routeLocations,
                                              stopCoordinates: model.routeStopCoordinates,
                                              stopNames: model.routeStopDisplayNames,
                                              mapStyle: model.routeMapStyle,
                                              topExtension: !model.showsMediaTabs
                                                  ? coverHeight - coverSpace : 0)
                                .frame(width: geo.size.width)
                                .modifier(PhotoCardTopClip(
                                    scroll: !model.showsMediaTabs ? coverScroll : nil,
                                    coverHeight: coverHeight, travel: coverSpace))
                        }

                        // Insights belong to the day itself, so they only
                        // accompany the photo/video tab — not screenshots or
                        // other images.
                        if model.showDayInsights,
                           (model.selectedMediaTab ?? .photoVideo) == .photoVideo,
                           model.insights != nil || model.friendSharedCount > 0 {
                            DayInsightsStrip(insights: model.insights ?? .init(),
                                             friendSharedCount: model.friendSharedCount)
                                .padding(.top, model.hasAnyLocation ? 0 : 8)
                        }

                        if usesContinuousPlaceCards {
                            grid(
                                model.sections.flatMap { gridEntries($0.blocks, placeCard: $0.placeCard) },
                                viewportSize: geo.size, marksPlaceCards: true
                            )
                            .padding(.top, sectionTopSpacing(for: 0))
                            .reveal(shouldRevealContent, delay: 0.42)
                        } else {
                            ForEach(Array(model.sections.enumerated()), id: \.element.id) { sIdx, section in
                                sectionView(section, index: sIdx, viewportSize: geo.size)
                                    .padding(.top, sectionTopSpacing(for: sIdx))
                            }
                        }

                        VStack(spacing: 0) {
                            // Hidden rather than removed so the page keeps its bottom spacing.
                            backCoverHint
                                .opacity(showsBackCoverHint ? 1 : 0)
                                .accessibilityHidden(!showsBackCoverHint)
                                .padding(.top, 96)
                            Color.clear.frame(height: 1).id("scroll_bottom")
                        }
                    }
                    .coordinateSpace(name: "dayContent")
                    // The card must be able to cover the photo completely
                    // even on days with little content.
                    .frame(minHeight: coverSpace + geo.size.height - headerHeight,
                           alignment: .top)
                    .padding(.bottom, 56)
                    .background {
                        EnclosingScrollViewReader { coverScroll.scrollView = $0 }
                            .frame(width: 0, height: 0)
                    }
                    .background(alignment: .top) {
                        PhotoCardBackground(scroll: coverScroll, coverHeight: coverHeight,
                                            travel: coverSpace,
                                            color: model.pageBackgroundColor)
                        // Bottom bounce must not reveal the back page.
                        .padding(.bottom, -1000)
                    }
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
                .scrollIndicators(.hidden)
                .scrollPosition($scrollPosition)
                .scrollTargetBehavior(PhotoCardSnapBehavior(
                    travel: coverSpace, scroll: coverScroll))
                // `scrollTo(y:)` excludes the header's content inset while
                // `contentOffset` includes it; report the offset in the
                // writable space so scrubber and anchor targets land exactly.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    scrubber.updateRawOffset(offset)
                    frameStore.contentScrollOffset = offset
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
                    frameStore.contentTopInset = inset
                }
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    let visible = CGRect(
                        x: 0, y: fixedHeaderHeight, width: geo.size.width,
                        height: max(0, geo.size.height - fixedHeaderHeight - bottomBarHeight))
                    return WaterfallLayoutPolicy.renderWindow(for: DayContentCoordinates.contentRect(
                        for: visible,
                        scrollOffset: geometry.contentOffset.y + geometry.contentInsets.top,
                        topInset: geometry.contentInsets.top))
                } action: { _, window in
                    waterfallViewport.updateWindow(window)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // The card's top rest is exactly `coverSpace`, so the
                    // title must already show there, not only past it.
                    geometry.contentOffset.y + geometry.contentInsets.top > coverSpace - 1
                } action: { _, scrolled in
                    headerTitleVisible = scrolled
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, scrolled in
                    updatePhotoCover(scrolled: scrolled,
                                     coverHeight: coverHeight, travel: coverSpace)
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    model.setPlaceInteraction(.scrolling, active: newPhase != .idle)
                    scrollPerformance.setScrolling(newPhase != .idle)
                    snapPhotoCard(from: oldPhase, to: newPhase,
                                  geometry: context.geometry, travel: coverSpace)
                }
                .environment(\.colorScheme, model.pageColorScheme)
                .environment(\.waterfallGeometrySink, frameStore.waterfall)
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
                    .revealFade(shouldRevealContent || (chromeRevealed?.wrappedValue ?? false),
                                delay: 0.5)
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .coordinateSpace(name: "dayScroll")
                .onChange(of: model.instanceID) {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("scroll_top") }
                }
                .onChange(of: model.selectedMediaTab) { _, _ in
                    // With the photo cover, the tabs stay where they are if
                    // the card has not reached the top yet.
                    if coverScroll.scrolled <= coverSpace { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("card_top", anchor: .top)
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
                    installPlaceAnchorCapture(viewportSize: geo.size)
                    recomputeScrollEdges(contentBounds: scrubber.contentBounds, viewportSize: geo.size)
                }
                .onChange(of: bottomBarHeight) { _, _ in
                    installPlaceAnchorCapture(viewportSize: geo.size)
                    recomputeScrollEdges(contentBounds: scrubber.contentBounds, viewportSize: geo.size)
                }
                .onChange(of: model.previewCurrentID) { oldID, id in
                    // Opening starts from a tapped, visible cell; only paging
                    // inside the preview needs to bring the grid along.
                    guard model.selected != nil, oldID != nil, let id else { return }
                    let cellID = model.gridCellID(forItemID: id)
                    // Only scroll when the target cell is off screen, so
                    // closing the preview preserves a visible cell's position.
                    // Cell frames are content-space; convert before testing.
                    if let cell = frameStore.cells[cellID] {
                        let midY = frameStore.screenRect(for: cell.rect).midY
                        if midY >= fixedHeaderHeight, midY <= geo.size.height {
                            return
                        }
                    }
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        if model.gridArrangement == .waterfall, let cell = frameStore.cells[cellID] {
                            scrollToGridFrame(cell.rect, viewportSize: geo.size, anchor: 0.5)
                        } else if let blockID = model.blockID(forItemID: id) {
                            proxy.scrollTo(blockID, anchor: .center)
                        }
                    }
                }
                .environment(\.colorScheme, model.pageColorScheme)

                HeroOverlayView(model: model,
                                frameStore: frameStore,
                                namespace: previewNamespace,
                                screen: geo.size,
                                request: $heroRequest)
              }
              .coordinateSpace(name: heroCoordinateSpace)
              .onAppear {
                  model.resumePlaceUpdates()
                  installPlaceAnchorCapture(viewportSize: geo.size)
              }
              .onChange(of: geo.size) { _, _ in installPlaceAnchorCapture(viewportSize: geo.size) }
              .onChange(of: scrubber.isScrubbing) { _, active in
                  model.setPlaceInteraction(.scrubbing, active: active)
              }
              .onChange(of: scrollDisabled || scrollFrozen, initial: true) { _, active in
                  model.setPlaceInteraction(.transitioning, active: active)
              }
              .backgroundPreferenceValue(WaterfallGeometryKey.self) { geometry in
                  Color.clear
                      .preference(key: HeroCellFrameKey.self, value: geometry.cells)
                      .preference(key: PlaceCardFrameKey.self, value: geometry.cards)
              }
              .onPreferenceChange(HeroCellFrameKey.self) {
                  frameStore.preferenceCells = $0
              }
              .backgroundPreferenceValue(HeroCellFrameKey.self) { cells in
                  Color.clear.preference(
                      key: DayGridSnapshotKey.self,
                      value: DayGridSnapshot(revision: gridRevision, frames: cells.mapValues(\.rect))
                  )
              }
              .backgroundPreferenceValue(PlaceCardFrameKey.self) { frames in
                  Color.clear.preference(
                      key: DayGridSnapshotKey.self,
                      value: DayGridSnapshot(revision: gridRevision, frames: frames)
                  )
              }
              .onPreferenceChange(DayGridSnapshotKey.self) { snapshot in
                  guard let snapshot else { return }
                  // Cell frames arrive in the content coordinate space;
                  // shift the screen viewport into that same space.
                  let viewport = CGRect(
                      x: 0, y: fixedHeaderHeight, width: geo.size.width,
                      height: max(0, geo.size.height - fixedHeaderHeight - bottomBarHeight)
                  )
                  let contentViewport = DayContentCoordinates.contentRect(
                      for: viewport, scrollOffset: frameStore.contentScrollOffset,
                      topInset: frameStore.contentTopInset)
                  let adjustment = gridAnchorTracker.update(
                      frames: snapshot.frames, revision: snapshot.revision,
                      viewport: contentViewport, offset: scrubber.metrics.offset,
                      enabled: shouldRevealContent && !scrollDisabled && !scrollFrozen
                          && model.selected == nil
                  )
                  var transaction = Transaction()
                  transaction.disablesAnimations = true
                  withTransaction(transaction) {
                      // Rotation, deletion or late caption loading can repack
                      // the hidden waterfall while a preview is open. Keep its
                      // current photo reachable without competing with the
                      // ordinary visible-card anchor restoration.
                      if model.gridArrangement == .waterfall, model.selected != nil,
                         let id = model.previewCurrentID,
                         let rect = snapshot.frames[id],
                         !contentViewport.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                          scrollToGridFrame(rect, viewportSize: geo.size, anchor: 0.5)
                      }
                      switch adjustment {
                      case .offset(let offset):
                          scrollPosition.scrollTo(y: offset)
                      case .reveal(let id):
                          if model.gridArrangement == .waterfall, let rect = snapshot.frames[id] {
                              scrollToGridFrame(rect, viewportSize: geo.size, anchor: 0)
                          } else if let blockID = model.blockID(forItemID: id) {
                              proxy.scrollTo(blockID, anchor: .top)
                          } else if model.sections.contains(where: { $0.placeCard?.id == id }) {
                              proxy.scrollTo(id, anchor: .top)
                          }
                      case nil:
                          break
                      }
                  }
              }
            }
        }
        .task(id: model.instanceID) {
            // Cache the top inset while the status bar is visible, before any
            // hero session might hide it. This prevents the ScrollView content
            // from shifting when the status bar toggles during preview open/close.
            stableTopInset = topSafeAreaInset()
            shouldRevealContent = false
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.spring(response: 0.82, dampingFraction: 0.90)) {
                shouldRevealContent = true
            }
            chromeRevealed?.wrappedValue = true
            await model.prepare()
        }
        .onDisappear {
            scrollPerformance.setScrolling(false)
            model.stopPlaceUpdates()
        }
    }

    /// Same style as the tunnel page's bottom hint.
    private var backCoverHint: some View {
        Text("上滑查看往年今日")
            .font(Theme.serif(12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .revealFade(shouldRevealContent, delay: 0.5)
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
                model.setPlaceInteraction(.pinching, active: true)
                pinchScale = scale
                let ratio = scale / pinchBaseline
                if ratio < 0.75 {
                    let newCount = min(6, model.gridColumnCount + 1)
                    if newCount != model.gridColumnCount {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withDayGridLayoutChange(model.gridArrangement) {
                            model.gridColumnCount = newCount
                        }
                        pinchBaseline = scale
                    }
                } else if ratio > 1.30 {
                    let newCount = max(1, model.gridColumnCount - 1)
                    if newCount != model.gridColumnCount {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withDayGridLayoutChange(model.gridArrangement) {
                            model.gridColumnCount = newCount
                        }
                        pinchBaseline = scale
                    }
                }
            }
            .onEnded { _ in
                pinchScale = 1.0
                pinchBaseline = 1.0
                model.setPlaceInteraction(.pinching, active: false)
            }
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
        HStack(spacing: 24) {
            ForEach(model.availableMediaTabs) { category in
                let isSelected = model.selectedMediaTab == category
                Button {
                    model.selectMediaTab(category)
                } label: {
                    Text(category.tabLabel)
                        .font(Theme.serif(15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink.opacity(isSelected ? 1 : 0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.bottom, 6)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("mediaTabs"))
                        } action: { mediaTabFrames[category] = $0 }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44, alignment: .bottom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.selected != nil || scrollDisabled)
                .accessibilityLabel(category.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("day-media-tab-\(category.rawValue)")
            }
        }
        .coordinateSpace(name: "mediaTabs")
        .overlay(alignment: .topLeading) {
            if let selected = model.selectedMediaTab, let frame = mediaTabFrames[selected] {
                Rectangle()
                    .fill(Theme.ink)
                    .frame(width: frame.width, height: 2)
                    .offset(x: frame.minX, y: frame.maxY - 2)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: frame)
                    // Grid rebuilds disable animations; the indicator has its own transaction.
                    .transaction { $0.disablesAnimations = false }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        .zIndex(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当天内容类别")
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    // MARK: Photo layouts

    private var usesContinuousPlaceCards: Bool {
        model.showsPlaceCardFlowOption && model.placeCardFlow == .continuous
            && model.sections.count >= 2 && model.sections.allSatisfy { $0.placeCard != nil }
    }

    private func gridLayoutRevision(viewportWidth: CGFloat) -> DayGridLayoutRevision {
        DayGridLayoutRevision(
            instanceID: model.instanceID,
            category: model.selectedMediaTab?.rawValue,
            arrangement: model.gridArrangement,
            columns: model.gridColumnCount,
            width: viewportWidth,
            sideSpacing: model.photoSideSpacing,
            horizontalSpacing: model.gridHorizontalSpacing,
            verticalSpacing: model.gridVerticalSpacing,
            border: model.borderWidth.rawValue,
            showsCaptions: model.showPhotoCaptions,
            captions: model.showPhotoCaptions ? model.gridCaptions : [],
            itemIDs: model.gridItemIDs,
            sections: model.sections.map(\.id),
            placeCardIDs: model.sections.compactMap { $0.placeCard?.id },
            cardPhotoFallbacks: Dictionary(uniqueKeysWithValues: model.sections.compactMap { section in
                section.placeCard.map { ($0.id, $0.firstPhotoID) }
            }),
            segmentationForm: model.placeSegmentationForm.rawValue,
            placeCardFlow: model.placeCardFlow,
            contentRevision: model.itemsRevision,
            titleSize: model.sectionTitleSize.size,
            titleFont: model.coverDateFont.rawValue,
            placeCardRatio: model.placeCardRatio.rawValue,
            placesRevision: model.placesLayoutRevision
        )
    }

    private func gridEntries(_ blocks: [MagazineBlock], placeCard: PlaceSectionCard?) -> [DayGridEntry] {
        let photos = blocks.flatMap { block in
            let expanded = block.groupID.map { model.expandedGroupIDs.contains($0) } ?? false
            let visible = block.groupID != nil && !expanded
                ? block.items.filter { $0.id == block.representativeID } : block.items
            return visible.enumerated().map { index, item in
                DayGridEntry.photo(PhotoGridEntry(
                    item: item, blockID: block.id, startsBlock: index == 0,
                    groupID: index == 0 ? block.groupID : nil,
                    hiddenCount: expanded ? 0 : max(block.items.count - 1, 0),
                    expanded: expanded))
            }
        }
        return (placeCard.map { [DayGridEntry.placeCard($0)] } ?? []) + photos
    }

    private func photoGrid(
        _ blocks: [MagazineBlock], placeCard: PlaceSectionCard? = nil, viewportSize: CGSize
    ) -> some View {
        grid(gridEntries(blocks, placeCard: placeCard), viewportSize: viewportSize)
    }

    @ViewBuilder
    private func grid(
        _ entries: [DayGridEntry], viewportSize: CGSize, marksPlaceCards: Bool = false
    ) -> some View {
        let sizing = DayPhotoGridSizing(
            viewportWidth: viewportSize.width, columnCount: model.gridColumnCount,
            horizontalSpacing: model.gridHorizontalSpacing, sideSpacing: model.photoSideSpacing
        )
        let count = sizing.columnCount
        let horizontalInset = sizing.sideInset
        let horizontalSpacing = sizing.horizontalSpacing
        let finalCellWidth = sizing.cellWidth
        let frameAlignment: Alignment = count == 1 ? .center : .leading
        if model.gridArrangement == .waterfall {
            let border = max((alignedGridBorderBase(for: count) * model.borderWidth.scale).rounded(), 0)
            VirtualWaterfallGrid(
                entries: entries,
                descriptors: entries.map { entry in
                    switch entry {
                    case .photo(let photo):
                        WaterfallItemDescriptor(
                            id: photo.id, content: .photo(
                                aspect: photo.item.aspectRatio, version: photo.item.contentVersion,
                                caption: model.showPhotoCaptions ? photo.item.caption : nil))
                    case .placeCard(let card):
                        WaterfallItemDescriptor(
                            id: card.id, content: .decoration(
                                height: PlaceSectionCard.Sizing(width: finalCellWidth, ratio: model.placeCardRatio).height))
                    }
                },
                columnCount: count, columnWidth: finalCellWidth,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: model.gridVerticalSpacing,
                border: border, cornerRadius: model.photoCornerRadius.value,
                viewport: waterfallViewport,
                pinnedIDs: Set([heroHiddenID, heroRequest?.id].compactMap { $0 }),
                marksPlaceCards: marksPlaceCards,
                layoutRevision: gridLayoutRevision(viewportWidth: viewportSize.width)
            ) { entry, metrics in
                switch entry {
                case .photo(let photo):
                    groupedPhotoCell(photo, width: finalCellWidth, virtualMetrics: metrics)
                case .placeCard(let card):
                    placeCardCell(card, width: finalCellWidth)
                }
            }
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            // Ordinary repacking stays atomic; only an explicit fold action
            // animates the buffered, visible cells.
            .transaction { if !$0.similarPhotoReflow { $0.animation = nil } }
        } else if model.gridLazyEnabled {
            let columns = Array(
                repeating: GridItem(.fixed(finalCellWidth), spacing: horizontalSpacing, alignment: .top),
                count: count
            )
            LazyVGrid(columns: columns, alignment: .leading, spacing: model.gridVerticalSpacing) {
                ForEach(entries) { entry in
                    gridEntryCell(entry, width: finalCellWidth, viewportSize: viewportSize)
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
                            gridEntryCell(entry, width: finalCellWidth, viewportSize: viewportSize)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                }
            }
            .padding(.horizontal, horizontalInset)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
    }

    @ViewBuilder
    private func gridEntryCell(
        _ entry: DayGridEntry, width: CGFloat, viewportSize: CGSize,
        marksPlaceCards: Bool = false
    ) -> some View {
        switch entry {
        case .photo(let photo):
            // Every layout gates its images on the viewport; the lazy toggle
            // only decides whether the aligned grid materializes cells lazily.
            let cell = ViewportPhotoCell(
                viewportSize: viewportSize,
                forceLoad: heroHiddenID == photo.id || heroRequest?.id == photo.id
            ) { loadsImage in
                groupedPhotoCell(photo, width: width, loadsImage: loadsImage)
            }
            .matchedGeometryEffect(id: photo.id, in: similarPhotoNamespace, properties: .position)
            if photo.startsBlock {
                cell.id(photo.blockID)
            } else {
                cell
            }
        case .placeCard(let card):
            placeCardCell(card, width: width)
            .id(card.id)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PlaceCardFrameKey.self,
                        value: [card.id: geometry.frame(in: .named(dayContentSpace))]
                    )
                    .preference(
                        key: SectionTopKey.self,
                        value: marksPlaceCards ? [card.id: geometry.frame(in: .named("dayContent")).minY] : [:]
                    )
                }
            }
        }
    }

    private func placeCardCell(_ card: PlaceSectionCard, width: CGFloat) -> some View {
        PlaceSectionCardView(
            card: card, width: width, ratio: model.placeCardRatio, font: model.coverDateFont,
            titleSize: model.sectionTitleSize.size, cornerRadius: model.photoCornerRadius.value,
            shadowLevel: model.photoShadow, style: model.placeCardStyle)
    }

    private func groupedPhotoCell(
        _ photo: PhotoGridEntry, width: CGFloat, loadsImage: Bool = true,
        virtualMetrics: WaterfallLayoutPolicy.CellMetrics? = nil
    ) -> some View {
        photoGridCell(photo.item, width: width, loadsImage: loadsImage,
                      virtualMetrics: virtualMetrics)
            .overlay(alignment: .bottomTrailing) {
                if let groupID = photo.groupID {
                    Button {
                        var transaction = Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.32))
                        transaction.similarPhotoReflow = true
                        withTransaction(transaction) {
                            model.toggleSimilarGroup(groupID)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: photo.expanded ? "chevron.up" : "square.on.square")
                            if !photo.expanded {
                                Text("+\(photo.hiddenCount)").monospacedDigit()
                            }
                        }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(height: 24)
                            .background(.black.opacity(0.65), in: Capsule())
                            // Keep the visible badge small without shrinking
                            // its accessible touch target.
                            .frame(minWidth: 44, minHeight: 44, alignment: .bottomTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(photo.expanded ? "收起相似照片" : "展开 \(photo.hiddenCount + 1) 张相似照片")
                    .padding(6)
                }
            }
    }

    private func photoGridCell(
        _ item: PhotoItem, width: CGFloat, loadsImage: Bool = true,
        virtualMetrics: WaterfallLayoutPolicy.CellMetrics? = nil
    ) -> some View {
        let count = min(max(model.gridColumnCount, 1), 6)
        let border = max(
            (alignedGridBorderBase(for: count) * model.borderWidth.scale).rounded(),
            0
        )
        let ratioRange = (CGFloat(9) / 20)...(CGFloat(16) / 9)

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
            loadsImage: loadsImage,
            measuredCaptionHeight: virtualMetrics?.captionHeight
        )
        .heroCell(id: item.id, hiddenID: heroHiddenID, reportsGeometry: virtualMetrics == nil)
        .onTapGesture { heroRequest = item }
        .contextMenu {
            Button {
                Task { await model.perform(.toggleFavorite, on: item) }
            } label: {
                Label(model.isFavorite(item) ? "取消收藏" : "收藏",
                      systemImage: model.isFavorite(item) ? "heart.slash" : "heart")
            }
            .disabled(!item.sharedCapabilities.canFavorite)
            if MediaFilter.supportsImageClassification(item.asset) {
                Menu {
                    Picker("图片分类", selection: Binding(
                        get: { ImageClassificationStore.shared.override(for: item.asset.localIdentifier) },
                        set: { choice in
                            ImageClassificationStore.shared.setOverride(choice, for: item.asset.localIdentifier)
                            model.refreshMediaClassifications()
                            if choice == .automatic {
                                Task { await OtherImageClassificationService.shared.classify([item.asset]) }
                            }
                        }
                    )) {
                        ForEach(ImageCategoryOverride.allCases, id: \.rawValue) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                } label: {
                    Label("图片分类", systemImage: "tag")
                }
            }
            Button {
                if model.setCover(item) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                Label("设为封面", systemImage: "photo.on.rectangle")
            }
            .disabled(model.photoCoverItem?.id == item.id)
            Button(role: .destructive) {
                Task { await model.perform(.delete, on: item) }
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!item.sharedCapabilities.canDelete)
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

    private static let cardTopPadding: CGFloat = 18

    private func updatePhotoCover(
        scrolled: CGFloat, coverHeight: CGFloat, travel: CGFloat
    ) {
        let delta = scrolled - coverScroll.scrolled
        if abs(delta) > 0.5 { coverScroll.lastDelta = delta }
        coverScroll.scrolled = scrolled
        let pull = max(0, -scrolled)
        if coverScroll.pull != pull { coverScroll.pull = pull }
        let phase = min(max(scrolled, 0), travel)
        if coverScroll.phase != phase { coverScroll.phase = phase }
        guard let binding = photoCardUnderTopBar else { return }
        let buttonMidY = stableTopInsetValue + DayTopBar.topSpacing + DayTopBar.buttonSize / 2
        let cardTop = DayPhotoCoverView.cardTop(phase: phase, coverHeight: coverHeight,
                                                travel: travel) + pull
        let underBar = cardTop <= buttonMidY
        if binding.wrappedValue != underBar { binding.wrappedValue = underBar }
    }

    /// Snaps whenever the release did not start `PhotoCardSpring` (no
    /// UIKit scroll view) or the scroll still stopped over the photo, such
    /// as a tap halting a snap. Programmatic scrolls (scrubber jumps) are
    /// left where they land.
    private func snapPhotoCard(
        from oldPhase: ScrollPhase, to newPhase: ScrollPhase,
        geometry: ScrollGeometry, travel: CGFloat
    ) {
        let scrolled = geometry.contentOffset.y + geometry.contentInsets.top
        if newPhase == .interacting { coverScroll.spring.stop() }
        guard !coverScroll.spring.isActive else { return }
        guard travel > 0, scrolled > 1, scrolled < travel - 1 else { return }
        let target: CGFloat
        switch (oldPhase, newPhase) {
        case (.interacting, .decelerating):
            target = coverScroll.lastDelta > 0 ? travel : 0
        case (.interacting, .idle), (.decelerating, .idle):
            target = PhotoCardSnapBehavior.restingTarget(forPosition: scrolled, travel: travel)
        default:
            return
        }
        if let scrollView = coverScroll.scrollView {
            coverScroll.spring.start(on: scrollView, to: target, velocity: 0)
            return
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: PhotoCardSpring.hapticIntensity)
        // Longer trips take longer, so a far snap does not look rushed.
        let distance = abs(target - scrolled) / travel
        let response = 0.55 + 0.3 * Double(distance)
        // `scrollTo(y:)` measures from the top rest, insets excluded.
        withAnimation(.spring(response: response, dampingFraction: 0.92)) {
            scrollPosition.scrollTo(y: target)
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

    /// Virtualized targets need no off-screen SwiftUI view or block scroll ID.
    private func scrollToGridFrame(_ rect: CGRect, viewportSize: CGSize, anchor: CGFloat) {
        let viewport = DayContentCoordinates.contentRect(
            for: CGRect(x: 0, y: fixedHeaderHeight, width: viewportSize.width,
                        height: max(0, viewportSize.height - fixedHeaderHeight - bottomBarHeight)),
            scrollOffset: frameStore.contentScrollOffset, topInset: frameStore.contentTopInset)
        if let target = DayContentCoordinates.targetOffset(
            for: rect, viewport: viewport,
            currentOffset: frameStore.contentScrollOffset, anchor: anchor) {
            scrollPosition.scrollTo(y: target)
        }
    }

    private func installPlaceAnchorCapture(viewportSize: CGSize) {
        model.beforePlacePresentation = {
            let viewport = DayContentCoordinates.contentRect(
                for: CGRect(
                    x: 0, y: fixedHeaderHeight, width: viewportSize.width,
                    height: max(0, viewportSize.height - fixedHeaderHeight - bottomBarHeight)),
                scrollOffset: frameStore.contentScrollOffset, topInset: frameStore.contentTopInset)
            gridAnchorTracker.capturePlaceAnchor(
                viewport: viewport, offset: frameStore.contentScrollOffset)
        }
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
    private func sectionView(
        _ section: MagazineSection, index: Int, viewportSize: CGSize
    ) -> some View {
        let rows = sectionRows(section)
        if !rows.isEmpty {
            let hasHeading = section.placeHeading != nil
                || section.placeHeadingPending
                || section.showsTimeHeading
            VStack(alignment: .leading, spacing: 0) {
                if let card = section.placeCard {
                    photoGrid(section.blocks, placeCard: card, viewportSize: viewportSize)
                } else {
                    sectionHeader(section)
                        .padding(.horizontal, 20)
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                        rowView(row, viewportSize: viewportSize)
                            .padding(.top, rowTopSpacing(index: idx, rows: rows) * (idx == 0 && !hasHeading ? 0.5 : 1))
                    }
                }
            }
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
            sectionHeading(section.placeHeading ?? PlaceNaming.loadingTitle,
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
        PlaceNameText(
            text: title, secondaryFont: model.coverDateFont.font(max(12, size * 0.62)))
            .font(model.coverDateFont.font(size))
            .foregroundStyle(Theme.ink)
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
    private func rowView(_ row: SectionRow, viewportSize: CGSize) -> some View {
        switch row {
        case .label(let text):
            Text(text)
                .font(Theme.serif(13))
                .foregroundStyle(Theme.ink.opacity(0.7))
                .padding(.horizontal, 20)
        case .grid(let blocks):
            photoGrid(blocks, viewportSize: viewportSize)
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
        model.selected != nil ? model.previewCurrentID.map { model.gridCellID(forItemID: $0) } : nil
    }

}

// MARK: - Section rows

/// A rendered row inside a section: a time label or photo layout.
private enum SectionRow {
    case label(String)
    case grid([MagazineBlock])
}

private struct PhotoGridEntry: Identifiable {
    let item: PhotoItem
    let blockID: UUID
    let startsBlock: Bool
    var groupID: String? = nil
    var hiddenCount: Int = 0
    var expanded = false

    var id: String { item.id }
}

private enum DayGridEntry: Identifiable {
    case photo(PhotoGridEntry)
    case placeCard(PlaceSectionCard)

    var id: String {
        switch self {
        case .photo(let photo): return photo.id
        case .placeCard(let card): return card.id
        }
    }
}

/// Separate from hero geometry so decorations cannot become preview sources.
private struct PlaceCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct DayGridSnapshot: Equatable {
    let revision: DayGridLayoutRevision
    let frames: [String: CGRect]
}

private struct DayGridSnapshotKey: PreferenceKey {
    static var defaultValue: DayGridSnapshot? = nil
    static func reduce(value: inout DayGridSnapshot?, nextValue: () -> DayGridSnapshot?) {
        guard let next = nextValue() else { return }
        if let previous = value, previous.revision == next.revision {
            value = DayGridSnapshot(
                revision: next.revision,
                frames: previous.frames.merging(next.frames) { _, new in new }
            )
        } else {
            value = next
        }
    }
}

// MARK: - Scroll tracking

/// Opt-in debug sampling only. Instruments remains the source of truth for
/// rendering hitches; this log makes repeated device runs easy to compare.
@MainActor
private final class DayScrollPerformanceProbe: NSObject {
    private let logger = Logger(subsystem: "OneDay", category: "ScrollPerformance")
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var slowFrames = 0
    private var worstGap: CFTimeInterval = 0

    func setScrolling(_ active: Bool) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-OneDayPerformanceTrace") else { return }
        if active {
            guard link == nil else { return }
            lastTimestamp = 0
            frames = 0
            slowFrames = 0
            worstGap = 0
            let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else if let link {
            link.invalidate()
            self.link = nil
            logger.debug("Scroll samples: \(self.frames), slow intervals: \(self.slowFrames), worst: \(self.worstGap * 1000) ms")
        }
        #endif
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let gap = link.timestamp - lastTimestamp
        let budget = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        frames += 1
        if gap > budget * 1.5 { slowFrames += 1 }
        worstGap = max(worstGap, gap)
    }
}

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
struct SectionTopKey: PreferenceKey {
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
