import SwiftUI

private struct DayPhotoViewportWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var dayPhotoViewportWidth: CGFloat? {
        get { self[DayPhotoViewportWidthKey.self] }
        set { self[DayPhotoViewportWidthKey.self] = newValue }
    }
}

/// Shared settings menu used by the cover, photo page, and back cover.
/// Provides a consistent ellipsis button that opens the full settings menu.
struct DaySettingsMenu: View {
    let model: DayViewModel
    var tint: Color = Theme.ink
    @AppStorage(CaptureClock.enabledKey) private var localCaptureTime = true
    @Environment(\.dayPhotoViewportWidth) private var photoViewportWidth

    var body: some View {
        Menu {
            Toggle("显示共享照片", isOn: Binding(
                get: { model.includeSharedAlbums },
                set: { model.includeSharedAlbums = $0 }
            ))
            Toggle("按拍摄地时间", isOn: Binding(
                get: { localCaptureTime },
                set: { enabled in
                    localCaptureTime = enabled
                    // Day membership and clock times both change: reload the
                    // day list and the open day exactly like a library change.
                    NotificationCenter.default.post(name: .photoLibraryContentChanged, object: nil)
                }
            ))
            Menu("背景") {
                Picker("", selection: Binding(
                    get: { model.background },
                    set: { model.background = $0 }
                )) {
                    ForEach(PageBackground.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
            Menu("布局") {
                Menu("排列") {
                    Picker("排列", selection: Binding(
                        get: { model.gridArrangement },
                        set: { arrangement in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                model.gridArrangement = arrangement
                            }
                        }
                    )) {
                        ForEach(DayGridArrangement.allCases) { arrangement in
                            Text(arrangement.label).tag(arrangement)
                        }
                    }
                }
                Menu("列数") {
                    Button {
                        withDayGridLayoutChange(model.gridArrangement) {
                            model.gridColumnMode = .automatic
                        }
                    } label: {
                        if model.gridColumnMode == .automatic {
                            Label("自动", systemImage: "checkmark")
                        } else {
                            Text("自动")
                        }
                    }
                    Menu {
                        Button("使用上次列数（\(Self.chineseColumnLabel(model.manualGridColumnCount))）") {
                            withDayGridLayoutChange(model.gridArrangement) {
                                model.gridColumnMode = .manual
                            }
                        }
                        Divider()
                        ForEach(1...6, id: \.self) { count in
                            Button {
                                withDayGridLayoutChange(model.gridArrangement) {
                                    model.gridColumnCount = count
                                }
                            } label: {
                                let label = Self.chineseColumnLabel(count)
                                if model.manualGridColumnCount == count {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    } label: {
                        if model.gridColumnMode == .manual {
                            Label("手动", systemImage: "checkmark")
                        } else {
                            Text("手动")
                        }
                    }
                }
                Menu("左右留白") {
                    Picker("左右留白", selection: Binding(
                        get: { model.photoSideSpacing },
                        set: { spacing in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                model.photoSideSpacing = spacing
                            }
                        }
                    )) {
                        ForEach(DayPhotoSideSpacing.allCases) { spacing in
                            Text(sideSpacingLabel(spacing)).tag(spacing)
                        }
                    }
                }
                Menu("横向间距") {
                    Button {
                        withDayGridLayoutChange(model.gridArrangement) {
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
                            withDayGridLayoutChange(model.gridArrangement) {
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
                            withDayGridLayoutChange(model.gridArrangement) {
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
            Menu("照片") {
                Menu("白边") {
                    Picker("宽度", selection: Binding(
                        get: { model.borderWidth },
                        set: { model.borderWidth = $0 }
                    )) {
                        ForEach(PhotoBorderWidth.allCases) { w in
                            Text(w.label).tag(w)
                        }
                    }
                }
                Menu("圆角") {
                    ForEach(PhotoCornerRadius.allCases) { cr in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                model.photoCornerRadius = cr
                            }
                        } label: {
                            if model.photoCornerRadius == cr {
                                Label(cr.label, systemImage: "checkmark")
                            } else {
                                Text(cr.label)
                            }
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
            }
            Menu("标题") {
                optionPicker("字体",
                           binding: Binding(get: { model.coverDateFont }, set: { model.coverDateFont = $0 }),
                           labelOf: { $0.label })
                Menu("大小") {
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
                Menu("分段") {
                    Toggle("地点分段", isOn: Binding(
                        get: { model.titlePlaceSegmentation },
                        set: { model.titlePlaceSegmentation = $0 }
                    ))
                    if model.titlePlaceSegmentation {
                        Menu("分段形式") {
                            Picker("分段形式", selection: Binding(
                                get: { model.placeSegmentationForm },
                                set: { model.placeSegmentationForm = $0 }
                            )) {
                                ForEach(TitleSegmentationPolicy.Form.allCases) { form in
                                    Text(form.label).tag(form)
                                }
                            }
                        }
                    }
                    if model.showsPlaceCardFlowOption {
                        Menu("卡片衔接") {
                            Picker("卡片衔接", selection: Binding(
                                get: { model.placeCardFlow },
                                set: { flow in
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) { model.placeCardFlow = flow }
                                }
                            )) {
                                ForEach(PlaceCardFlow.allCases) { flow in
                                    Text(flow.label).tag(flow)
                                }
                            }
                        }
                    }
                    if model.showsNestedTimeSegmentationOption {
                        Toggle("地点下时间分段", isOn: Binding(
                            get: { model.titleNestedTimeSegmentation },
                            set: { model.titleNestedTimeSegmentation = $0 }
                        ))
                    }
                    Toggle("时间分段", isOn: Binding(
                        get: { model.titleTimeSegmentation },
                        set: { model.titleTimeSegmentation = $0 }
                    ))
                }
            }
            Menu("按钮") {
                Toggle("底部工具栏", isOn: Binding(
                    get: { model.showBottomToolbar },
                    set: { model.showBottomToolbar = $0 }
                ))
                Toggle("段落刻度", isOn: Binding(
                    get: { model.showScrubberSectionMarks },
                    set: { model.showScrubberSectionMarks = $0 }
                ))
                Toggle("细线震动", isOn: Binding(
                    get: { model.scrubberTickHaptics },
                    set: { model.scrubberTickHaptics = $0 }
                ))
                Toggle("系统滚动条", isOn: Binding(
                    get: { model.showDayScrollIndicator },
                    set: { model.showDayScrollIndicator = $0 }
                ))
                Toggle("文字导航", isOn: Binding(
                    get: { model.showTextDayNavigation },
                    set: { model.showTextDayNavigation = $0 }
                ))
            }
            if model.hasAnyLocation {
                Menu("地图") {
                    Toggle("轨迹地图", isOn: Binding(
                        get: { model.showPhotoMap },
                        set: { model.showPhotoMap = $0 }
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
            }
            Toggle("说明", isOn: Binding(
                get: { model.showPhotoCaptions },
                set: { model.showPhotoCaptions = $0 }
            ))
            // Required by the bundled GeoNames data's CC BY 4.0 license:
            // source, license, and that the data was modified.
            Section("地名与时区数据来自 GeoNames，依据 CC BY 4.0 许可使用，经筛选和压缩处理") {
                Link("GeoNames 官网", destination: URL(string: "https://www.geonames.org")!)
                Link("CC BY 4.0 许可", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/deed.zh-hans")!)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    // MARK: - Helpers

    private func sideSpacingLabel(_ spacing: DayPhotoSideSpacing) -> String {
        guard let width = photoViewportWidth else {
            // Standalone hosts without a page width can only show the ratio.
            return "\(Int(spacing.fraction * 100))%"
        }
        return DayPhotoGridSizing(
            viewportWidth: width, columnCount: model.gridColumnCount,
            horizontalSpacing: model.gridHorizontalSpacing, sideSpacing: spacing
        ).sideInsetLabel
    }

    @ViewBuilder
    private func optionPicker<T: CaseIterable & Identifiable & Equatable>(
        _ title: String,
        binding: Binding<T>,
        labelOf: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        Menu(title) {
            ForEach(Array(T.allCases)) { opt in
                Button { binding.wrappedValue = opt } label: {
                    if binding.wrappedValue == opt {
                        Label(labelOf(opt), systemImage: "checkmark")
                    } else {
                        Text(labelOf(opt))
                    }
                }
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

/// Glass close button shared by the fixed top bar and the photo page header.
struct DayCloseButton: View {
    var tint: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: DayTopBar.buttonSize, height: DayTopBar.buttonSize)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}

/// Hides top-bar buttons without changing layout. The switch is never
/// animated: the fixed bar and the photo page header swap their buttons in
/// place, and a cross-fade would briefly show two stacked glass circles.
struct TopButtonVisibility: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(nil, value: visible)
    }
}

/// Safe-area top bar of a scrolling page (photo page, back cover). Its button
/// slots sit exactly under the fixed `DayTopBar` buttons and stay invisible
/// unless `showsButtons`; the date title slides in once the page scrolls.
///
/// The visible title gives the system's soft scroll edge effect content to
/// blur behind even when the button slots are transparent.
struct DayPageHeader: View {
    static let bottomSpacing: CGFloat = 8
    /// Scroll distance after which the title appears.
    static let titleRevealOffset: CGFloat = 4

    let model: DayViewModel
    let title: String
    let titleVisible: Bool
    let topInset: CGFloat
    /// Real (hideable) buttons in the slots; nil leaves the slots empty.
    var onClose: (() -> Void)? = nil
    var showsButtons = false

    /// Bar height for a given top inset, for pages that pad their content
    /// to a fixed position below the bar.
    static func height(topInset: CGFloat) -> CGFloat {
        topInset + DayTopBar.topSpacing + DayTopBar.buttonSize + bottomSpacing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onClose {
                DayCloseButton(action: onClose)
                    .modifier(TopButtonVisibility(visible: showsButtons))
            } else {
                buttonSlot
            }
            Text(title)
                .font(model.coverDateFont.font(20))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .opacity(titleVisible ? 1 : 0)
                .offset(y: titleVisible ? 0 : 10)
                .animation(.spring(response: 0.36, dampingFraction: 0.88), value: titleVisible)
                .accessibilityHidden(!titleVisible)
            if onClose != nil {
                DaySettingsMenu(model: model)
                    .modifier(TopButtonVisibility(visible: showsButtons))
            } else {
                buttonSlot
            }
        }
        .padding(.horizontal, DayTopBar.horizontalPadding)
        .padding(.top, topInset + DayTopBar.topSpacing)
        .padding(.bottom, Self.bottomSpacing)
        .frame(maxWidth: .infinity)
    }

    private var buttonSlot: some View {
        Color.clear.frame(width: DayTopBar.buttonSize, height: DayTopBar.buttonSize)
    }
}

/// Full-screen top bar with close button (leading) and settings menu
/// (trailing). Drawn once above all pages of `DayPagedStackView`, so it stays
/// put while pages flip. Its geometry must match the photo page header
/// (`DayMagazineView.fixedHeader`), which keeps invisible stand-ins for these
/// buttons to preserve its layout.
struct DayTopBar: View {
    static let buttonSize: CGFloat = 38
    static let horizontalPadding: CGFloat = 16
    static let topSpacing: CGFloat = 4

    let model: DayViewModel
    let onClose: () -> Void
    var tint: Color = Theme.ink
    var topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DayCloseButton(tint: tint, action: onClose)
                Spacer(minLength: 0)
                DaySettingsMenu(model: model, tint: tint)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, topInset + Self.topSpacing)
            Spacer(minLength: 0)
        }
    }
}
