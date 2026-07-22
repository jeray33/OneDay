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
                }
                .scrollDisabled(activeDragBlock != nil || scrollDisabled)
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
                //.frame(height: 38)
                .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }
            menuButton
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeAreaInset() + 4)
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    private var selectableTemplates: [BlockTemplate] {
        BlockTemplate.allCases.filter { $0.isSelectable }
    }
    private var allTemplatesEnabled: Bool {
        selectableTemplates.allSatisfy { model.enabledTemplates.contains($0) }
    }

    private var pageFlipMenu: some View {
        Menu("翻页模式") {
            ForEach(PageFlipMode.allCases) { mode in
                Button {
                    model.pageFlipMode = mode
                } label: {
                    if model.pageFlipMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
            if model.pageFlipMode == .staggeredPhysics
                || model.pageFlipMode == .continuousStaggered {
                Divider()
                Toggle("顶部防露边（上移 10）", isOn: Binding(
                    get: { model.staggeredTopLiftEnabled },
                    set: { model.staggeredTopLiftEnabled = $0 }
                ))
            }
        }
    }

    /// Builds a labeled submenu that works like a Picker but reliably shows SF Symbols icons.
    @ViewBuilder
    private func animPicker<T: CaseIterable & Identifiable & Equatable>(
        _ title: String, icon: String? = nil,
        binding: Binding<T>,
        labelOf: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        Menu {
            ForEach(Array(T.allCases)) { opt in
                Button { binding.wrappedValue = opt } label: {
                    if binding.wrappedValue == opt {
                        Label(labelOf(opt), systemImage: "checkmark")
                    } else {
                        Text(labelOf(opt))
                    }
                }
            }
        } label: {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
    }

    private var menuButton: some View {
        Menu {
            Menu("背景") {
                Picker("", selection: Binding(
                    get: { model.background },
                    set: { model.background = $0 }
                )) {
                    ForEach(PageBackground.allCases) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
                if model.background == .dominant || model.background == .vibrant {
                    Divider()
                    Toggle("分段配色", isOn: Binding(
                        get: { model.sectionTintEnabled },
                        set: { model.sectionTintEnabled = $0 }
                    ))
                }
            }
            Menu("布局") {
                Toggle("全选", isOn: Binding(
                    get: { allTemplatesEnabled },
                    set: { on in
                        model.enabledTemplates = on
                            ? Set(selectableTemplates)
                            : [.single]
                    }
                ))
                Divider()
                ForEach(selectableTemplates, id: \.self) { t in
                    Toggle(t.label, isOn: Binding(
                        get: { model.enabledTemplates.contains(t) },
                        set: { on in
                            if on {
                                model.enabledTemplates.insert(t)
                            } else if model.enabledTemplates.count > 1 {
                                model.enabledTemplates.remove(t)
                            }
                        }
                    ))
                }
            }
            Menu("白边") {
                Picker("宽度", selection: Binding(
                    get: { model.borderWidth },
                    set: { model.borderWidth = $0 }
                )) {
                    ForEach(PhotoBorderWidth.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                Picker("颜色", selection: Binding(
                    get: { model.borderStyle },
                    set: { model.borderStyle = $0 }
                )) {
                    ForEach(PhotoBorderStyle.allCases) { s in
                        Label(s.label, systemImage: s.icon).tag(s)
                    }
                }
            }
            Menu("动效") {
                Section("入场") {
                    animPicker("缩放幅度", icon: "arrow.up.left.and.arrow.down.right",
                               binding: Binding(get: { model.scrollScale },    set: { model.scrollScale = $0 }),
                               labelOf: { $0.label })
                    animPicker("运动距离", icon: "arrow.up.and.down",
                               binding: Binding(get: { model.scrollMovement }, set: { model.scrollMovement = $0 }),
                               labelOf: { $0.label })
                    animPicker("旋转角度", icon: "rotate.right",
                               binding: Binding(get: { model.scrollRotation }, set: { model.scrollRotation = $0 }),
                               labelOf: { $0.label })
                    animPicker("模糊半径", icon: "camera.filters",
                               binding: Binding(get: { model.scrollBlur },     set: { model.scrollBlur = $0 }),
                               labelOf: { $0.label })
                }
                Section("节奏") {
                    animPicker("弹簧曲线", icon: "waveform",
                               binding: Binding(get: { model.scrollSpring },   set: { model.scrollSpring = $0 }),
                               labelOf: { $0.label })
                    animPicker("时差层次", icon: "stopwatch",
                               binding: Binding(get: { model.scrollStagger },  set: { model.scrollStagger = $0 }),
                               labelOf: { $0.label })
                }
                Section("消失") {
                    animPicker("淡出透明", icon: "eye.slash",
                               binding: Binding(get: { model.scrollFade },     set: { model.scrollFade = $0 }),
                               labelOf: { $0.label })
                    animPicker("速度差",  icon: "arrow.up.arrow.down",
                               binding: Binding(get: { model.scrollParallax }, set: { model.scrollParallax = $0 }),
                               labelOf: { $0.label })
                }
                Section("立体") {
                    animPicker("X轴倒住", icon: "square.3.layers.3d.top.filled",
                               binding: Binding(get: { model.scrollTiltX },    set: { model.scrollTiltX = $0 }),
                               labelOf: { $0.label })
                    animPicker("Y轴倒住", icon: "square.3.layers.3d.middle.filled",
                               binding: Binding(get: { model.scrollTiltY },    set: { model.scrollTiltY = $0 }),
                               labelOf: { $0.label })
                    animPicker("角度递减", icon: "arrow.down.right.and.arrow.up.left",
                               binding: Binding(get: { model.scrollTiltDecay }, set: { model.scrollTiltDecay = $0 }),
                               labelOf: { $0.label })
                }
            }
            pageFlipMenu
            animPicker("封面日期字体",
                       binding: Binding(get: { model.coverDateFont }, set: { model.coverDateFont = $0 }),
                       labelOf: { $0.label })
            Toggle("地点工具条", isOn: Binding(
                get: { model.showLocationBar },
                set: { model.showLocationBar = $0 }
            ))
            Button {
                model.isDragEnabled.toggle()
            } label: {
                Label(model.isDragEnabled ? "锁定照片位置" : "自由摆放照片",
                      systemImage: model.isDragEnabled ? "lock" : "hand.draw")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
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
            .font(model.coverDateFont.font(56))
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
        }
    }

    private func rowTopSpacing(index: Int, rows: [SectionRow]) -> CGFloat {
        let row = rows[index]
        if index == 0 {
            if case .label = row { return 6 }
            return 24
        }
        switch (rows[index - 1], row) {
        case (_, .label):       return 80   // start of a new time segment
        case (.label, .block):  return 12   // photo tucked under its time label
        case (.block, .block):  return 56
        }
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
            return blocks.map { .block($0) }
        }
        if last.timeIntervalSince(first) <= 2 * 3600 {
            return [.label(timeRangeText(first, last))] + blocks.map { .block($0) }
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
            rows.append(contentsOf: bucketBlocks.map { .block($0) })
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

/// A rendered row inside a section: either a time-segment label or a photo block.
private enum SectionRow {
    case label(String)
    case block(MagazineBlock)
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
