import SwiftUI
import UIKit

struct DayMagazineView: View {
    var model: DayViewModel
    var dateNamespace: Namespace.ID
    var dateIsSource: Bool
    var contentRevealed: Bool
    var onClose: () -> Void
    var onReroll: () -> Void
    var prevDate: Date? = nil
    var nextDate: Date? = nil
    var onPrevDay: (() -> Void)? = nil
    var onNextDay: (() -> Void)? = nil
    var navLoading: Bool = false
    var scrollEdgesBinding: Binding<ContentScrollEdges>? = nil
    var scrollDisabled: Bool = false

    @Namespace private var previewNamespace

    // Free-canvas dragging
    @State private var activeDragBlock: UUID?
    @State private var liveTranslation: CGSize = .zero
    @State private var revealContent = false
    @State private var activeSegmentID: String?
    @State private var pinchScale: CGFloat = 1.0
    @State private var pinchBaseline: CGFloat = 1.0

    private var shouldRevealContent: Bool {
        contentRevealed && revealContent
    }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = geo.size.width - 40
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: model.sectionTintActive ? 0 : 96) {
                        Color.clear.frame(height: 0).id("scroll_top")

                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { sIdx, section in
                            sectionView(section, index: sIdx, contentWidth: contentWidth)
                        }

                        Color.clear.frame(height: 1).id("scroll_bottom")
                    }
                    .padding(.top, topSafeAreaInset() + 24)
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .highPriorityGesture(columnPinchGesture)
                }
                .scrollDisabled(activeDragBlock != nil || scrollDisabled || pinchScale != 1.0)
                .background(model.pageBackgroundColor.ignoresSafeArea())
                .environment(\.colorScheme, model.pageColorScheme)
                .animation(.easeInOut(duration: 0.35), value: model.background)
                .animation(.easeInOut(duration: 0.35), value: model.sectionTintEnabled)
                .coordinateSpace(name: "dayScroll")
                .onChange(of: model.instanceID) {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("scroll_top") }
                }
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
                .onPreferenceChange(BlockPositionKey.self) { updateActiveSegment($0) }
                .overlay(alignment: .top) { topOverlay(proxy: proxy) }
            }
        }
        .onShake {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            onReroll()
        }
        .task(id: model.instanceID) {
            revealContent = false
            try? await Task.sleep(nanoseconds: 160_000_000)
            withAnimation(.spring(response: 0.82, dampingFraction: 0.90)) {
                revealContent = true
            }
            await model.prepare()
        }
        .fullScreenCover(item: selectedBinding) { item in
            PhotoPreviewView(model: model, current: item, namespace: previewNamespace)
                .navigationTransition(.zoom(sourceID: item.id, in: previewNamespace))
        }
        .sheet(item: albumPickerBinding) { item in
            AlbumPickerSheet(item: item, model: model, onFinish: {})
        }
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
                guard model.photoLayoutMode == .alignedGrid else { return }
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

    @ViewBuilder
    private func topOverlay(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            if model.routeStops.count >= 2 && model.showLocationBar {
                let stops = model.routeStops.map {
                    RouteSelectorView.Stop(id: $0.id, name: $0.name)
                }
                RouteSelectorView(stops: stops, activeID: activeSegmentID) { id in
                    guard let stop = model.routeStops.first(where: { $0.id == id }),
                          let target = model.scrollTarget(for: stop) else { return }
                    withAnimation(.easeInOut(duration: 0.55)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
            DaySettingsMenu(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeAreaInset() + 4)
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    // MARK: Block row (with optional free-canvas dragging)

    @ViewBuilder
    private func blockRow(_ block: MagazineBlock, contentWidth: CGFloat) -> some View {
        let committed = model.blockOffsets[block.id] ?? .zero
        let live = activeDragBlock == block.id ? liveTranslation : .zero
        let isActive = activeDragBlock == block.id

        MagazineBlockView(
            block: block,
            width: contentWidth,
            namespace: previewNamespace,
            config: model.layoutConfig,
            frameColor: { model.frameColor(for: $0) },
            isFavorite: { model.isFavorite($0) },
            onSelect: { open($0) },
            onAction: { action, item in
                Task { await model.perform(action, on: item) }
            }
        )
        .frame(maxWidth: .infinity)
        .scrollTransition(.animated(model.scrollSpring.animation)) { content, phase in
            let sc  = model.scrollScale.value
            let mv  = model.scrollMovement.value
            let rot = model.scrollRotation.value
            let fa  = model.scrollFade.offScreenOpacity
            let blr = CGFloat(model.scrollBlur.radius)
            let baseY: CGFloat = phase == .bottomTrailing ?  mv :
                                  phase == .topLeading     ? -mv * 0.64 : 0
            return content
                .opacity(phase.isIdentity ? 1 : fa)
                .scaleEffect(
                    phase == .topLeading     ? (1.0 - sc) :
                    phase == .bottomTrailing ? (1.0 + sc) : 1.0
                )
                .rotationEffect(.degrees(
                    phase == .topLeading     ?  rot :
                    phase == .bottomTrailing ? -rot : 0
                ))
                .offset(y: baseY)
                .blur(radius: phase == .bottomTrailing ? blr * CGFloat(phase.value) : 0)
        }
        // Continuous 3D tilt + parallax driven by live scroll position.
        // phase.value: -1 (top) → 0 (center) → +1 (bottom).
        .scrollTransition(.interactive) { content, phase in
            // -- Parallax lag (above center only) --
            let par    = model.scrollParallax.factor
            let pv     = min(0.0, phase.value)
            let parY   = CGFloat(-pv) * par

            // -- 3D perspective tilt --
            let xDeg   = CGFloat(model.scrollTiltX.degrees)
            let yDeg   = CGFloat(model.scrollTiltY.degrees)
            let decay  = model.scrollTiltDecay.power
            let v      = phase.value
            // Apply decay curve: sign preserved, magnitude adjusted by power
            let absV   = abs(v)
            let signV  = v >= 0 ? 1.0 : -1.0
            let eV     = CGFloat(signV * pow(absV, decay))
            return content
                .rotation3DEffect(.degrees(eV * xDeg), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .rotation3DEffect(.degrees(eV * yDeg), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .offset(y: parY)
        }
        .overlay(alignment: .topTrailing) {
            if model.isDragEnabled {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
            }
        }
        .offset(x: committed.width + live.width, y: committed.height + live.height)
        .scaleEffect(isActive ? 1.04 : 1)
        .shadow(color: .black.opacity(isActive ? 0.22 : 0),
                radius: isActive ? 14 : 0, y: isActive ? 8 : 0)
        .zIndex(isActive ? 10 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
        .gesture(canvasGesture(for: block),
                 including: model.isDragEnabled ? .all : .subviews)
        .id(block.id)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: BlockPositionKey.self,
                    value: [block.id.uuidString: geo.frame(in: .named("dayScroll")).minY])
            }
        )
    }

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
                            .background(blockPositionReader(for: entry.blockID))
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
                                    .background(blockPositionReader(for: entry.blockID))
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
            (alignedGridBorderBase(for: count) * model.layoutConfig.borderScale).rounded(),
            0
        )
        let ratioRange = (CGFloat(9) / 20)...(CGFloat(16) / 9)
        let polaroidMinimum = min(20, max(5, width * 0.12))
        let scrollAnimation = model.scrollSpring.animation
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
            ratioRange: ratioRange,
            borderColor: model.frameColor(for: item),
            polaroid: model.borderStyle.isPolaroid,
            minimumPolaroidBottom: polaroidMinimum,
            shadowLevel: model.photoShadow
        )
        .matchedTransitionSource(id: item.id, in: previewNamespace)
        .onTapGesture { open(item) }
        .contextMenu {
            Button {
                Task { await model.perform(.toggleFavorite, on: item) }
            } label: {
                Label(model.isFavorite(item) ? "取消收藏" : "收藏",
                      systemImage: model.isFavorite(item) ? "heart.slash" : "heart")
            }
            Button {
                Task { await model.perform(.pickAlbum, on: item) }
            } label: {
                Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
            }
            Button(role: .destructive) {
                Task { await model.perform(.delete, on: item) }
            } label: {
                Label("删除", systemImage: "trash")
            }
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

    private func blockPositionReader(for blockID: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: BlockPositionKey.self,
                value: [blockID.uuidString: geo.frame(in: .named("dayScroll")).minY]
            )
        }
    }

    private func updateActiveSegment(_ positions: [String: CGFloat]) {
        guard !positions.isEmpty else { return }
        let anchorY: CGFloat = 150
        // Current block = the last one whose top has passed the anchor line.
        let passed = positions.filter { $0.value <= anchorY }
        let currentKey = passed.max(by: { $0.value < $1.value })?.key
            ?? positions.min(by: { $0.value < $1.value })?.key
        guard let key = currentKey, let uuid = UUID(uuidString: key),
              let sid = model.stopID(forBlockID: uuid), sid != activeSegmentID else { return }
        activeSegmentID = sid
    }

    private func updateScrollEdges(_ edges: ContentScrollEdges) {
        if let binding = scrollEdgesBinding, binding.wrappedValue != edges {
            binding.wrappedValue = edges
        }
    }

    private func canvasGesture(for block: MagazineBlock) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture())
            .onChanged { value in
                if case .second(true, let drag) = value {
                    if activeDragBlock != block.id {
                        activeDragBlock = block.id
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    liveTranslation = drag?.translation ?? .zero
                }
            }
            .onEnded { value in
                if case .second(_, let drag?) = value {
                    let base = model.blockOffsets[block.id] ?? .zero
                    model.blockOffsets[block.id] = CGSize(width: base.width + drag.translation.width,
                                                          height: base.height + drag.translation.height)
                }
                activeDragBlock = nil
                liveTranslation = .zero
            }
    }

    // MARK: Sections

    @ViewBuilder
    private func sectionView(_ section: MagazineSection, index: Int, contentWidth: CGFloat) -> some View {
        let rows = sectionRows(section)
        if !rows.isEmpty {
            let tint = model.sectionTintActive
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(section)
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    rowView(row, contentWidth: contentWidth)
                        .padding(.top, rowTopSpacing(index: idx, rows: rows))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, tint ? 40 : 0)
            .padding(.bottom, tint ? 120 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint ? model.sectionBackgroundColor(section) : Color.clear)
            .environment(\.colorScheme, tint ? model.sectionColorScheme(section) : model.pageColorScheme)
            .reveal(shouldRevealContent, delay: 0.42 + Double(index) * 0.14)
        }
    }

    private func sectionHeader(_ section: MagazineSection) -> some View {
        // When the day moves across distinct places, the headline is the place
        // name; otherwise it's the uppercase-English time-of-day band.
        let showPlace = model.hasRoute
        let title = showPlace ? (section.placeName ?? section.band.englishTitle)
                              : section.band.englishTitle
        return Text(title)
            .font(model.coverDateFont.font(model.sectionTitleSize.size))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: SectionRow, contentWidth: CGFloat) -> some View {
        switch row {
        case .label(let text):
            Text(text)
                .font(Theme.serif(13))
                .foregroundStyle(Theme.ink.opacity(0.7))
        case .block(let block):
            blockRow(block, contentWidth: contentWidth)
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
    /// with photo blocks. A section spanning ≤ 2h gets one label under the
    /// title; a longer section is split into clock-aligned 2-hour segments,
    /// each labelled above its first photo with that segment's actual span.
    private func sectionRows(_ section: MagazineSection) -> [SectionRow] {
        let blocks = section.blocks.filter { $0.template != .quote }
        guard !blocks.isEmpty else { return [] }
        let allDates = blocks.flatMap(\.items).compactMap(\.creationDate).sorted()
        guard let first = allDates.first, let last = allDates.last else {
            return contentRows(for: blocks)
        }
        if last.timeIntervalSince(first) <= 2 * 3600 {
            return [.label(timeRangeText(first, last))] + contentRows(for: blocks)
        }
        var rows: [SectionRow] = []
        var currentBucket: Date?
        var bucketBlocks: [MagazineBlock] = []
        func flush() {
            guard !bucketBlocks.isEmpty else { return }
            let dates = bucketBlocks.flatMap(\.items).compactMap(\.creationDate).sorted()
            if let f = dates.first, let l = dates.last {
                rows.append(.label(timeRangeText(f, l)))
            }
            rows.append(contentsOf: contentRows(for: bucketBlocks))
            bucketBlocks.removeAll()
        }
        for block in blocks {
            let t = block.items.compactMap(\.creationDate).min() ?? first
            let bucket = alignedBucket(t)
            if currentBucket == nil { currentBucket = bucket }
            if bucket != currentBucket { flush(); currentBucket = bucket }
            bucketBlocks.append(block)
        }
        flush()
        return rows
    }

    private func contentRows(for blocks: [MagazineBlock]) -> [SectionRow] {
        switch model.photoLayoutMode {
        case .magazine:
            return blocks.map { .block($0) }
        case .alignedGrid:
            return [.grid(blocks)]
        }
    }

    /// Rounds a date down to a clock-aligned even hour (…14:00, 16:00…).
    private func alignedBucket(_ date: Date) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        c.hour = ((c.hour ?? 0) / 2) * 2
        c.minute = 0
        c.second = 0
        return cal.date(from: c) ?? date
    }

    private func timeRangeText(_ start: Date, _ end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let s = f.string(from: start), e = f.string(from: end)
        return s == e ? s : "\(s) - \(e)"
    }

    private var footer: some View {
        // The day navigation footer has moved to the back cover. A small spacer
        // is kept so the bottom sentinel has something to anchor against.
        Color.clear.frame(height: 24)
    }

    private func open(_ item: PhotoItem) {
        model.selected = item
    }
}

// MARK: - Section rows

/// A rendered row inside a section: a time label, magazine block, or aligned photo grid.
private enum SectionRow {
    case label(String)
    case block(MagazineBlock)
    case grid([MagazineBlock])
}

private struct AlignedGridEntry: Identifiable {
    let item: PhotoItem
    let blockID: UUID
    let startsBlock: Bool

    var id: String { item.id }
}

// MARK: - Scroll tracking

private struct BlockPositionKey: PreferenceKey {
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
