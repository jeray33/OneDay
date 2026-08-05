import SwiftUI

/// Shared settings menu used by the cover, photo page, and back cover.
/// Provides a consistent ellipsis button that opens the full settings menu.
struct DaySettingsMenu: View {
    let model: DayViewModel

    private var selectableTemplates: [BlockTemplate] {
        BlockTemplate.allCases.filter { $0.isSelectable }
    }
    private var allTemplatesEnabled: Bool {
        selectableTemplates.allSatisfy { model.enabledTemplates.contains($0) }
    }

    var body: some View {
        Menu {
            Toggle("显示共享照片", isOn: Binding(
                get: { model.includeSharedAlbums },
                set: { model.includeSharedAlbums = $0 }
            ))
            Menu("识别共享相簿") {
                let titles = PhotoLibraryService.shared.allRegularAlbumTitles()
                if titles.isEmpty {
                    Text("没有可识别的相簿")
                } else {
                    ForEach(titles, id: \.self) { title in
                        Toggle(title, isOn: Binding(
                            get: { model.sharedAlbumNames.contains(title) },
                            set: { isOn in
                                if isOn {
                                    model.sharedAlbumNames.append(title)
                                } else {
                                    model.sharedAlbumNames.removeAll { $0 == title }
                                }
                            }
                        ))
                    }
                }
            }
            Menu("背景") {
                Picker("", selection: Binding(
                    get: { model.background },
                    set: { model.background = $0 }
                )) {
                    ForEach(PageBackground.allCases) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
                if model.background == .dominant || model.background == .vibrant || model.background == .bright || model.background == .bright2 {
                    Divider()
                    Toggle("分段配色", isOn: Binding(
                        get: { model.sectionTintEnabled },
                        set: { model.sectionTintEnabled = $0 }
                    ))
                }
            }
            Menu("布局") {
                Menu("排版方式") {
                    ForEach(PhotoLayoutMode.allCases) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                model.photoLayoutMode = mode
                            }
                        } label: {
                            if model.photoLayoutMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
                Divider()
                if model.photoLayoutMode == .magazine {
                    Menu("照片组合") {
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
                } else {
                    Menu("列数") {
                        ForEach(1...6, id: \.self) { count in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    model.gridColumnCount = count
                                }
                            } label: {
                                let label = Self.chineseColumnLabel(count)
                                if model.gridColumnCount == count {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                    Menu("横向间距") {
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                model.gridHorizontalSpacing = nil
                            }
                        } label: {
                            if model.gridHorizontalSpacing == nil {
                                Label("自动", systemImage: "checkmark")
                            } else {
                                Text("自动")
                            }
                        }
                        Divider()
                        ForEach(Self.gridHorizontalSpacingOptions, id: \.self) { spacing in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    model.gridHorizontalSpacing = spacing
                                }
                            } label: {
                                let label = Self.spacingLabel(spacing)
                                if model.gridHorizontalSpacing == spacing {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                    Menu("纵向间距") {
                        ForEach(Self.gridVerticalSpacingOptions, id: \.self) { spacing in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    model.gridVerticalSpacing = spacing
                                }
                            } label: {
                                let label = Self.spacingLabel(spacing)
                                if model.gridVerticalSpacing == spacing {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                    Toggle("懒加载", isOn: Binding(
                        get: { model.gridLazyEnabled },
                        set: { model.gridLazyEnabled = $0 }
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
            Menu("投影") {
                ForEach(PhotoShadowLevel.allCases) { level in
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.photoShadow = level
                        }
                    } label: {
                        if model.photoShadow == level {
                            Label(level.label, systemImage: "checkmark")
                        } else {
                            Text(level.label)
                        }
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
            animPicker("标题字体",
                       binding: Binding(get: { model.coverDateFont }, set: { model.coverDateFont = $0 }),
                       labelOf: { $0.label })
            Menu("标题大小") {
                ForEach(SectionTitleSize.allCases) { size in
                    Button {
                        model.sectionTitleSize = size
                    } label: {
                        if model.sectionTitleSize == size {
                            Label(size.label, systemImage: "checkmark")
                        } else {
                            Text(size.label)
                        }
                    }
                }
            }
            Menu("封面模式") {
                ForEach(CoverMode.allCases, id: \.self) { mode in
                    Button {
                        model.coverMode = mode
                    } label: {
                        if model.coverMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
            animPicker("封面封底背景色",
                       binding: Binding(
                        get: { model.coverBackgroundMode },
                        set: { model.coverBackgroundMode = $0 }
                       ),
                       labelOf: { $0.label })
            Toggle("地点工具条", isOn: Binding(
                get: { model.showLocationBar },
                set: { model.showLocationBar = $0 }
            ))
            if model.hasAnyLocation {
                Toggle("轨迹地图", isOn: Binding(
                    get: { model.showPhotoMap },
                    set: { model.showPhotoMap = $0 }
                ))
                Toggle("顶部渐变模糊", isOn: Binding(
                    get: { model.mapProgressiveBlurEnabled },
                    set: { model.mapProgressiveBlurEnabled = $0 }
                ))
                Menu("地图融合") {
                    ForEach(MapBlendMode.allCases) { mode in
                        Button {
                            model.mapBlendMode = mode
                        } label: {
                            if model.mapBlendMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
            }
            Toggle("显示说明文字", isOn: Binding(
                get: { model.showPhotoCaptions },
                set: { model.showPhotoCaptions = $0 }
            ))
            if model.photoLayoutMode == .magazine {
                Button {
                    model.isDragEnabled.toggle()
                } label: {
                    Label(model.isDragEnabled ? "锁定照片位置" : "自由摆放照片",
                          systemImage: model.isDragEnabled ? "lock" : "hand.draw")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    // MARK: - Page flip menu

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

    // MARK: - Helpers

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

    static func chineseColumnLabel(_ count: Int) -> String {
        switch count {
        case 1: return "一列"
        case 2: return "两列"
        case 3: return "三列"
        case 4: return "四列"
        case 5: return "五列"
        default: return "六列"
        }
    }

    static let gridHorizontalSpacingOptions: [CGFloat] = [
        0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40
    ]

    static let gridVerticalSpacingOptions: [CGFloat] = [
        0, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64
    ]

    static func spacingLabel(_ spacing: CGFloat) -> String {
        "\(Int(spacing)) pt"
    }
}

/// Shared top bar with close button (leading) and settings menu (trailing).
/// Used by the cover, photo page, and back cover for consistent chrome.
struct DayTopBar: View {
    let model: DayViewModel
    let onClose: (() -> Void)?
    var tint: Color = Theme.ink

    var body: some View {
        VStack {
            HStack {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(tint)
                            .frame(width: 38, height: 38)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                }
                Spacer()
                DaySettingsMenu(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.top, topSafeAreaInset() + 6)
            Spacer()
        }
    }
}
