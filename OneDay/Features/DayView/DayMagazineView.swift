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
                    VStack(spacing: 96) {
                        Color.clear.frame(height: 0).id("scroll_top")
                        masthead

                        ForEach(Array(model.sections.enumerated()), id: \.element.id) { sIdx, section in
                            VStack(alignment: .leading, spacing: 56) {
                                sectionHeader(section)
                                ForEach(section.blocks) { block in
                                    blockRow(block, contentWidth: contentWidth)
                                }
                            }
                            .reveal(shouldRevealContent, delay: 0.42 + Double(sIdx) * 0.14)
                        }

                        footer.reveal(shouldRevealContent, delay: 0.72)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
                .scrollDisabled(activeDragBlock != nil)
                .background(model.pageBackgroundColor.ignoresSafeArea())
                .environment(\.colorScheme, model.pageColorScheme)
                .animation(.easeInOut(duration: 0.35), value: model.background)
                .coordinateSpace(name: "dayScroll")
                .onChange(of: model.instanceID) {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("scroll_top") }
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
            closeButton
            if model.routeStops.count >= 2 {
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
        //.padding(.top, 8)
        .revealFade(shouldRevealContent, delay: 0.32)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var selectableTemplates: [BlockTemplate] {
        BlockTemplate.allCases.filter { $0.isSelectable }
    }
    private var allTemplatesEnabled: Bool {
        selectableTemplates.allSatisfy { model.enabledTemplates.contains($0) }
    }

    /// Builds a labeled submenu that works like a Picker but reliably shows SF Symbols icons.
    @ViewBuilder
    private func animPicker<T: CaseIterable & Identifiable & Equatable>(
        _ title: String, icon: String,
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
            Label(title, systemImage: icon)
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

    private var masthead: some View {
        VStack(spacing: 14) {
            BigDateView(date: model.date)
                .matchedGeometryEffect(id: "flowDate", in: dateNamespace, isSource: dateIsSource)

            VStack(spacing: 14) {
                if let caption = DateText.relativeCaption(model.date) {
                    Text(caption)
                        .font(Theme.serif(22, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(Theme.accent)
                }
                metaLine
                if model.hasRoute {
                    DayMapPatch(locations: model.routeLocations, kilometers: model.travelKilometers)
                        .padding(.top, 10)
                }
            }
            .reveal(shouldRevealContent, delay: 0.22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.bottom, 6)
    }

    private var metaLine: some View {
        let places = model.headerPlaces.prefix(2).joined(separator: " · ")
        var parts: [String] = []
        if model.photoCount > 0 { parts.append("\(model.photoCount) 张照片") }
        if model.videoCount > 0 { parts.append("\(model.videoCount) 段视频") }
        return VStack(spacing: 4) {
            Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 40, height: 1)
            Text(parts.joined(separator: " · "))
                .font(Theme.serif(13))
                .foregroundStyle(.secondary)
            if !places.isEmpty {
                Text(places)
                    .font(Theme.serif(13, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ section: MagazineSection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .font(Theme.serif(26, weight: .bold))
                .foregroundStyle(Theme.ink)
            if let place = section.placeName {
                Text(place)
                    .font(Theme.serif(13))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            Text(section.timeText)
                .font(Theme.serif(12))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(spacing: 22) {
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
            .padding(.horizontal, 6)
            .overlay {
                if navLoading {
                    ProgressView().scaleEffect(0.7).tint(Theme.ink)
                }
            }

            Rectangle().fill(Theme.ink.opacity(0.15)).frame(width: 50, height: 1)
            Button(action: onReroll) {
                Label("再来一天", systemImage: "shuffle")
                    .font(Theme.serif(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: 52)
                    .background(Capsule().fill(Theme.ink))
            }
            Text("摇一摇，换一天")
                .font(Theme.serif(12))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 24)
        .padding(.bottom, 40)
    }

    private func open(_ item: PhotoItem) {
        model.selected = item
    }

    private static func navDateText(_ date: Date) -> String {
        let c = DateText.components(date)
        return "\(c.year).\(c.month).\(c.day)"
    }
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
