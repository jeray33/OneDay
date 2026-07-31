import SwiftUI
import UIKit

struct PhotoPreviewView: View {
    let model: DayViewModel
    let namespace: Namespace.ID
    /// Host-driven fade for background + chrome during the open/close hero
    /// transition (0 while flying in/out, 1 when fully presented).
    var sessionOpacity: Double = 1
    /// Host-driven opacity of the photo card. 0 while the flight layer owns the
    /// photo, 1 once it has landed.
    var cardOpacity: Double = 1
    var onSelectionChanged: (String) -> Void = { _ in }
    /// Requests close. Passes the live drag translation, scale and the current
    /// photo id so the host can fly the photo back to its grid cell.
    var onClose: (CGSize, CGFloat, String) -> Void = { _, _, _ in }
    @AppStorage("OneDay.previewSwipeYawEnabled") private var swipeYawEnabled = true
    @AppStorage("OneDay.previewSwipeYawLevel") private var swipeYawLevel = SwipeYawLevel.medium.rawValue
    @AppStorage("OneDay.previewSwipeGlossEnabled") private var swipeGlossEnabled = true
    @AppStorage("OneDay.previewSwipeGlossLevel") private var swipeGlossLevel = SwipeGlossLevel.medium.rawValue
    @AppStorage("OneDay.previewSwipeSpeedBiasEnabled") private var swipeSpeedBiasEnabled = false
    @AppStorage("OneDay.previewSwipeSpeedBiasLevel") private var swipeSpeedBiasLevel = SwipeSpeedBiasLevel.medium.rawValue

    @State private var selection: String
    @State private var dragOffset: CGSize = .zero
    @State private var isZoomed = false
    @State private var albumItem: PhotoItem?
    @State private var editingItem: PhotoItem?
    @State private var dynamicBg: Color?
    @State private var showAlbumConfig = false
    @State private var tagAlbums: [AlbumInfo] = []
    @State private var membershipIDs: Set<String> = []
    @State private var isMutatingAlbum = false
    @State private var isMutatingHidden = false
    @State private var pendingDeleteIDs: [String] = []
    @State private var showPendingDelete = false
    @State private var stagingDeleteScale: CGFloat = 1
    @State private var isStagingDelete = false
    @State private var isClosing = false
    @State private var flipAngle: Double = 0
    @State private var isFlipTransitioning = false
    @State private var observedHorizontalSwipe = false
    @State private var pendingSwipeSettleHaptic = false
    @State private var dragStartSelection: String?
    @State private var isVerticalDragLocked = false
    @State private var verticalDragItemID: String?
    @State private var undoItemID: String?
    @State private var undoOffset: CGSize = .zero
    @State private var undoScale: CGFloat = 1

    init(model: DayViewModel, current: PhotoItem, namespace: Namespace.ID,
         sessionOpacity: Double = 1, cardOpacity: Double = 1,
         onSelectionChanged: @escaping (String) -> Void = { _ in },
         onClose: @escaping (CGSize, CGFloat, String) -> Void = { _, _, _ in }) {
        self.model = model
        self.namespace = namespace
        self.sessionOpacity = sessionOpacity
        self.cardOpacity = cardOpacity
        self.onSelectionChanged = onSelectionChanged
        self.onClose = onClose
        _selection = State(initialValue: current.id)
    }

    private var allItems: [PhotoItem] { model.allItems }
    private var visibleItems: [PhotoItem] {
        allItems.filter { !pendingDeleteIDs.contains($0.id) }
    }
    private var currentItem: PhotoItem? { visibleItems.first { $0.id == selection } }
    private var pendingDeleteItems: [PhotoItem] {
        pendingDeleteIDs.compactMap { id in allItems.first { $0.id == id } }
    }
    private var pendingDeleteLastItem: PhotoItem? {
        guard let lastID = pendingDeleteIDs.last else { return nil }
        return allItems.first { $0.id == lastID }
    }

    private var dragProgress: CGFloat {
        min(max(dragOffset.height, 0) / 320, 1)
    }
    private var deleteProgress: CGFloat {
        min(max(-dragOffset.height, 0) / 280, 1)
    }
    private var activeScale: CGFloat {
        let base = 1 - dragProgress * 0.18 - deleteProgress * 0.45
        return max(0.08, base) * stagingDeleteScale
    }
    private var controlsOpacity: Double {
        let progress = max(dragProgress, deleteProgress)
        return Double(max(0, 1 - progress * 2))
    }
    private var swipeEffectConfig: SwipePreviewEffectConfig {
        SwipePreviewEffectConfig(
            yawEnabled: swipeYawEnabled,
            yawMaxDegrees: SwipeYawLevel(rawValue: swipeYawLevel)?.degrees ?? SwipeYawLevel.medium.degrees,
            glossEnabled: swipeGlossEnabled,
            glossStrength: SwipeGlossLevel(rawValue: swipeGlossLevel)?.strength ?? SwipeGlossLevel.medium.strength,
            speedBiasEnabled: swipeSpeedBiasEnabled,
            incomingOffsetFactor: SwipeSpeedBiasLevel(rawValue: swipeSpeedBiasLevel)?.incomingOffsetFactor ?? SwipeSpeedBiasLevel.medium.incomingOffsetFactor,
            outgoingOffsetFactor: SwipeSpeedBiasLevel(rawValue: swipeSpeedBiasLevel)?.outgoingOffsetFactor ?? SwipeSpeedBiasLevel.medium.outgoingOffsetFactor
        )
    }
    private var isFlippedToBack: Bool {
        flipAngle > 90
    }
    private var isFlipActive: Bool {
        isFlipTransitioning || flipAngle > 0.001
    }

    var body: some View {
        ZStack {
            (dynamicBg ?? model.pageBackgroundColor)
                .ignoresSafeArea()
                .opacity(sessionOpacity * Double(1 - dragProgress))

            TabView(selection: $selection) {
                ForEach(visibleItems) { item in
                    PreviewPageView(
                        item: item,
                        model: model,
                        onZoomChanged: { isZoomed = $0 },
                        onEditCaption: { editingItem = $0 },
                        photoOffsetX: 0,
                        photoOffsetY: 0,
                        photoScale: 1,
                        infoOpacity: (isZoomed || isFlipActive) ? 0 : controlsOpacity,
                        isZoomed: isZoomed,
                        flipAngle: flipAngle,
                        swipeEffectConfig: swipeEffectConfig,
                        onFlipRequest: { requestFlip(toBack: true) },
                        onFlipBackRequest: { requestFlip(toBack: false) }
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .opacity((isVerticalDragLocked ? 0 : 1) * cardOpacity)
            .allowsHitTesting(!isVerticalDragLocked && !isFlipActive && !isClosing)
            .simultaneousGesture(dismissDrag)

            verticalDragOverlay
            undoRestoreOverlay
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomControls }
        .statusBarHidden()
        .sheet(item: $albumItem) { item in
            AlbumPickerSheet(item: item, model: model, onFinish: {})
        }
        .sheet(item: $editingItem) { item in
            CaptionEditorSheet(item: item) { caption in
                Task { await model.updateCaption(caption, for: item) }
            }
        }
        .sheet(isPresented: $showAlbumConfig) {
            AlbumConfigSheet(model: model) {
                refreshTagAlbums()
            }
        }
        .sheet(isPresented: $showPendingDelete) {
            PendingDeleteSheet(
                items: pendingDeleteItems,
                onCancel: {
                    pendingDeleteIDs.removeAll()
                    showPendingDelete = false
                    performDismiss()
                },
                onConfirm: { selectedIDs in
                    Task { await confirmPendingDelete(selectedIDs: selectedIDs) }
                }
            )
        }
        .onAppear {
            onSelectionChanged(selection)
            refreshTagAlbums()
            refreshMembership()
            ensureValidSelectionAfterFiltering()
        }
        .onChange(of: selection) {
            // A vertical dismiss drag pins `selection` back to its start every
            // frame; running the resets below then would zero `dragOffset` and
            // fight the live drag, making the card snap to full size and shake
            // (issues when dragging up/down then sideways). Skip entirely while
            // vertically locked.
            guard !isVerticalDragLocked else { return }
            // Defer committing the page to the grid until a drag settles, so
            // transient TabView paging during a fast flick doesn't churn it.
            if dragStartSelection == nil {
                onSelectionChanged(selection)
            }
            isZoomed = false
            dragOffset = .zero
            flipAngle = 0
            isFlipTransitioning = false
            if pendingSwipeSettleHaptic {
                pendingSwipeSettleHaptic = false
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.prepare()
                feedback.impactOccurred(intensity: 0.55)
            }
            refreshMembership()
        }
        .onChange(of: pendingDeleteIDs) {
            ensureValidSelectionAfterFiltering()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isFlippedToBack {
                requestFlip(toBack: false)
            }
        }
        .task(id: selection) {
            await updateDynamicBackground()
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            albumTagBar
            bottomActionBar
        }
        .padding(.bottom, bottomSafeAreaInset() + 10)
        .offset(y: (isZoomed || isFlipActive) ? 18 : 0)
        .opacity(((isZoomed || isFlipActive) ? 0 : controlsOpacity) * sessionOpacity)
        .animation(.easeInOut(duration: 0.22), value: isZoomed || isFlipActive)
        .allowsHitTesting(!(isZoomed || isFlipActive) && max(dragProgress, deleteProgress) < 0.15
                          && !isMutatingAlbum && !isMutatingHidden && !isStagingDelete)
    }

    private func updateDynamicBackground() async {
        guard let item = currentItem else { return }
        let color = await model.photoDerivedBackground(for: item)
        withAnimation(.easeInOut(duration: 0.45)) { dynamicBg = color }
    }

    private func requestClose() {
        if pendingDeleteIDs.isEmpty {
            performDismiss()
        } else {
            showPendingDelete = true
        }
    }

    /// Close from a button / programmatic path: hand back to the host with a
    /// resting card (no drag), letting it fly the photo home.
    private func performDismiss() {
        guard !isClosing else { return }
        isClosing = true
        onClose(.zero, 1, selection)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed, !isStagingDelete, !isFlipActive else { return }
                if dragStartSelection == nil { dragStartSelection = selection }
                let t = value.translation
                if abs(t.width) > 12, abs(t.width) > abs(t.height) {
                    observedHorizontalSwipe = true
                }
                if !isVerticalDragLocked && !observedHorizontalSwipe {
                    // Once this drag has been recognized as a horizontal browse,
                    // never switch it into the up/down dismiss/delete mode, even
                    // if the finger later moves vertically (until it lifts).
                    let enoughDistance = abs(t.height) > 8 || abs(t.width) > 8
                    if enoughDistance && abs(t.height) > abs(t.width) {
                        isVerticalDragLocked = true
                        verticalDragItemID = dragStartSelection ?? selection
                    }
                }
                if isVerticalDragLocked {
                    dragOffset = CGSize(width: value.translation.width * 0.35,
                                        height: value.translation.height)
                    if let dragStartSelection, selection != dragStartSelection {
                        selection = dragStartSelection
                    }
                }
            }
            .onEnded { value in
                guard !isZoomed, !isStagingDelete, !isFlipActive else { return }
                let startedSelection = dragStartSelection
                dragStartSelection = nil
                let horizontalDistance = abs(value.translation.width)
                if observedHorizontalSwipe && horizontalDistance > 20 {
                    pendingSwipeSettleHaptic = true
                    Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        if pendingSwipeSettleHaptic {
                            pendingSwipeSettleHaptic = false
                        }
                    }
                }
                observedHorizontalSwipe = false
                guard isVerticalDragLocked else {
                    // Horizontal browse settled: commit the final page now that
                    // the drag is over (mid-drag updates were suppressed above).
                    onSelectionChanged(selection)
                    return
                }
                let verticalDominant = abs(value.translation.height) > abs(value.translation.width)
                guard verticalDominant else {
                    isVerticalDragLocked = false
                    verticalDragItemID = nil
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = .zero
                        stagingDeleteScale = 1
                    }
                    return
                }
                if let startedSelection, selection != startedSelection {
                    selection = startedSelection
                }

                let downFarEnough = value.translation.height > 80
                    || value.predictedEndTranslation.height > 240
                let upFarEnough = value.translation.height < -180
                    || value.predictedEndTranslation.height < -460

                if upFarEnough {
                    Task { await stageCurrentForDeletion() }
                    return
                }
                if downFarEnough {
                    if !pendingDeleteIDs.isEmpty {
                        isVerticalDragLocked = false
                        verticalDragItemID = nil
                        showPendingDelete = true
                        return
                    }
                    guard !isClosing else { return }
                    isClosing = true
                    // Keep the dragged card shown (via verticalDragOverlay) so the
                    // flight layer takes over from its exact on-screen position.
                    onClose(dragOffset, activeScale, selection)
                    return
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = .zero
                    stagingDeleteScale = 1
                }
                isVerticalDragLocked = false
                verticalDragItemID = nil
            }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { requestClose() } label: {
                icon("xmark")
            }
            Spacer(minLength: 4)
            pendingDeleteBadge
            Spacer(minLength: 4)
            if let item = currentItem {
                Menu {
                    Menu("照片操作") {
                        Button {
                            editingItem = item
                        } label: {
                            Label("编辑说明", systemImage: "pencil")
                        }
                        Button {
                            albumItem = item
                        } label: {
                            Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                    Menu("显示与布局") {
                        Toggle(isOn: Binding(
                            get: { model.showAlbumTagBar },
                            set: { model.showAlbumTagBar = $0 }
                        )) {
                            Label("相簿标签栏", systemImage: "rectangle.stack")
                        }
                    }
                    Menu("横滑视觉效果") {
                        Toggle(isOn: $swipeYawEnabled) {
                            Label("Y轴转角", systemImage: "rotate.3d")
                        }
                        if swipeYawEnabled {
                            Picker("转角幅度", selection: $swipeYawLevel) {
                                ForEach(SwipeYawLevel.allCases, id: \.rawValue) { level in
                                    Text(level.label).tag(level.rawValue)
                                }
                            }
                        }
                        Divider()
                        Toggle(isOn: $swipeGlossEnabled) {
                            Label("反光效果", systemImage: "sparkles")
                        }
                        if swipeGlossEnabled {
                            Picker("反光强度", selection: $swipeGlossLevel) {
                                ForEach(SwipeGlossLevel.allCases, id: \.rawValue) { level in
                                    Text(level.label).tag(level.rawValue)
                                }
                            }
                        }
                        Divider()
                        Toggle(isOn: $swipeSpeedBiasEnabled) {
                            Label("速度差", systemImage: "gauge.with.dots.needle.33percent")
                        }
                        if swipeSpeedBiasEnabled {
                            Picker("速度差参数", selection: $swipeSpeedBiasLevel) {
                                ForEach(SwipeSpeedBiasLevel.allCases, id: \.rawValue) { level in
                                    Text(level.label).tag(level.rawValue)
                                }
                            }
                        }
                    }
                } label: {
                    icon("ellipsis")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeAreaInset() + 8)
        .offset(y: (isZoomed || isFlipActive) ? -14 : 0)
        .opacity(((isZoomed || isFlipActive) ? 0 : controlsOpacity) * sessionOpacity)
        .animation(.easeInOut(duration: 0.22), value: isZoomed || isFlipActive)
    }

    @ViewBuilder
    private var pendingDeleteBadge: some View {
        if let item = pendingDeleteLastItem, !pendingDeleteIDs.isEmpty {
            Button {
                showPendingDelete = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    PHImageView(
                        asset: item.asset,
                        displaySize: CGSize(width: 20, height: 20),
                        fill: true,
                        highQuality: false
                    )
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text("\(pendingDeleteIDs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(.red, in: Capsule())
                        .offset(x: 7, y: -7)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 34, height: 34)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 40, height: 40)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        if let item = currentItem {
            HStack {
                Button {
                    Task { await model.toggleFavorite(item) }
                } label: {
                    let fav = model.isFavorite(item)
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(fav ? Theme.accent : .black)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                if !pendingDeleteIDs.isEmpty {
                    Button {
                        undoLastStaged()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .disabled(undoItemID != nil || isStagingDelete)
                }
                Spacer()
                Button {
                    Task { await hideCurrentItem() }
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .disabled(isMutatingHidden)
                Button {
                    model.showAlbumTagBar.toggle()
                } label: {
                    Image(systemName: model.showAlbumTagBar ? "rectangle.stack.badge.minus" : "rectangle.stack.badge.plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var albumTagBar: some View {
        if model.showAlbumTagBar {
            AlbumTagBar(
                albums: tagAlbums,
                membershipIDs: membershipIDs,
                onConfigure: { showAlbumConfig = true },
                onTapAlbum: { album in
                    Task { await toggleCurrentPhoto(in: album) }
                }
            )
        }
    }

    private func refreshTagAlbums() {
        tagAlbums = model.enabledAlbums()
        refreshMembership()
    }

    private func refreshMembership() {
        guard let item = currentItem else {
            membershipIDs = []
            return
        }
        membershipIDs = model.albumIDs(containing: item, among: tagAlbums)
    }

    private func toggleCurrentPhoto(in album: AlbumInfo) async {
        guard !isMutatingAlbum, let item = currentItem else { return }
        isMutatingAlbum = true
        defer { isMutatingAlbum = false }

        if membershipIDs.contains(album.id) {
            let ok = await model.removeFromAlbum(album, item: item)
            guard ok else { return }
            membershipIDs.remove(album.id)
        } else {
            let ok = await model.addToAlbum(album, item: item)
            guard ok else { return }
            membershipIDs.insert(album.id)
            advanceToNextPhoto()
        }
    }

    private func advanceToNextPhoto() {
        guard let idx = visibleItems.firstIndex(where: { $0.id == selection }),
              idx + 1 < visibleItems.count else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            selection = visibleItems[idx + 1].id
        }
    }

    private func hideCurrentItem() async {
        guard !isMutatingHidden, let item = currentItem else { return }
        isMutatingHidden = true
        defer { isMutatingHidden = false }
        let ids = visibleItems.map(\.id)
        let currentIndex = ids.firstIndex(of: item.id)
        let nextID: String?
        if let currentIndex {
            if currentIndex + 1 < ids.count {
                nextID = ids[currentIndex + 1]
            } else if currentIndex > 0 {
                nextID = ids[currentIndex - 1]
            } else {
                nextID = nil
            }
        } else {
            nextID = nil
        }
        let ok = await model.setHidden(true, item: item)
        guard ok else { return }
        if let nextID {
            withAnimation(.easeInOut(duration: 0.28)) {
                selection = nextID
            }
        } else {
            requestClose()
        }
    }

    private func stageCurrentForDeletion() async {
        guard let item = currentItem, !isStagingDelete else { return }
        if pendingDeleteIDs.contains(item.id) {
            advanceAfterStaging(from: item.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = .zero }
            isVerticalDragLocked = false
            verticalDragItemID = nil
            return
        }
        isStagingDelete = true
        withAnimation(.easeIn(duration: 0.3)) {
            dragOffset = CGSize(width: dragOffset.width, height: -360)
            stagingDeleteScale = 0.08
        }
        try? await Task.sleep(nanoseconds: 320_000_000)
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.7)
        pendingDeleteIDs.append(item.id)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            dragOffset = .zero
            stagingDeleteScale = 1
        }
        advanceAfterStaging(from: item.id)
        isStagingDelete = false
        isVerticalDragLocked = false
        verticalDragItemID = nil
    }

    private func advanceAfterStaging(from currentID: String) {
        let ids = allItems.map(\.id)
        guard let currentIndex = ids.firstIndex(of: currentID) else { return }

        func pick(indices: [Int]) -> String? {
            for i in indices where !pendingDeleteIDs.contains(ids[i]) {
                return ids[i]
            }
            return nil
        }

        let forward = Array((currentIndex + 1)..<ids.count)
        let backward = Array((0..<currentIndex).reversed())
        let targetID = pick(indices: forward) ?? pick(indices: backward)
        guard let targetID else {
            showPendingDelete = true
            return
        }
        selection = targetID
    }

    private func confirmPendingDelete(selectedIDs: Set<String>) async {
        guard !selectedIDs.isEmpty else { return }
        let targetItems = pendingDeleteItems.filter { selectedIDs.contains($0.id) }
        guard !targetItems.isEmpty else { return }
        do {
            try await PhotoActionService.shared.delete(targetItems.map(\.asset))
            model.removeItems(ids: selectedIDs)
            pendingDeleteIDs.removeAll { selectedIDs.contains($0) }
            showPendingDelete = false
            performDismiss()
        } catch {
            // Keep sheet open on failure/cancel.
        }
    }

    private func ensureValidSelectionAfterFiltering() {
        guard !visibleItems.isEmpty else {
            if !pendingDeleteIDs.isEmpty { showPendingDelete = true }
            return
        }
        if !visibleItems.contains(where: { $0.id == selection }) {
            selection = visibleItems[0].id
        }
    }

    @ViewBuilder
    private var verticalDragOverlay: some View {
        if isVerticalDragLocked,
           let lockedID = verticalDragItemID,
           let item = visibleItems.first(where: { $0.id == lockedID }) {
            PreviewPageView(
                item: item,
                model: model,
                onZoomChanged: { isZoomed = $0 },
                onEditCaption: { editingItem = $0 },
                photoOffsetX: dragOffset.width,
                photoOffsetY: dragOffset.height,
                photoScale: activeScale,
                infoOpacity: (isZoomed || isFlipActive) ? 0 : controlsOpacity,
                isZoomed: isZoomed,
                flipAngle: flipAngle,
                swipeEffectConfig: swipeEffectConfig,
                onFlipRequest: { requestFlip(toBack: true) },
                onFlipBackRequest: { requestFlip(toBack: false) }
            )
            .opacity(cardOpacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// Reverse of the staging animation: the last staged photo flies back down
    /// from the top-shrunken position to its resting state.
    @ViewBuilder
    private var undoRestoreOverlay: some View {
        if let undoID = undoItemID,
           let item = allItems.first(where: { $0.id == undoID }) {
            PreviewPageView(
                item: item,
                model: model,
                onZoomChanged: { _ in },
                onEditCaption: { _ in },
                photoOffsetX: undoOffset.width,
                photoOffsetY: undoOffset.height,
                photoScale: undoScale,
                infoOpacity: 0,
                isZoomed: false,
                flipAngle: 0,
                swipeEffectConfig: swipeEffectConfig,
                onFlipRequest: {},
                onFlipBackRequest: {}
            )
            .opacity(cardOpacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func undoLastStaged() {
        guard undoItemID == nil, !isStagingDelete,
              let lastID = pendingDeleteIDs.last,
              allItems.contains(where: { $0.id == lastID }) else { return }
        undoItemID = lastID
        undoOffset = CGSize(width: 0, height: -360)
        undoScale = 0.08
        withAnimation(.easeOut(duration: 0.4)) {
            undoOffset = .zero
            undoScale = 1
        }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred(intensity: 0.7)
            pendingDeleteIDs.removeAll { $0 == lastID }
            selection = lastID
            undoItemID = nil
        }
    }

    private func requestFlip(toBack: Bool) {
        guard !isStagingDelete else { return }
        if toBack {
            guard !isFlippedToBack, !isFlipTransitioning, !isZoomed else { return }
        } else {
            guard (isFlippedToBack || isFlipTransitioning), !isFlipTransitioning else { return }
        }
        isFlipTransitioning = true
        withAnimation(.easeInOut(duration: 0.6)) {
            flipAngle = toBack ? 180 : 0
        }
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            isFlipTransitioning = false
        }
    }
}

private enum SwipeSpeedBiasLevel: String, CaseIterable {
    case subtle
    case medium
    case high

    var label: String {
        switch self {
        case .subtle: return "轻微"
        case .medium: return "标准"
        case .high: return "明显"
        }
    }

    var incomingOffsetFactor: Double {
        switch self {
        case .subtle: return 0.10
        case .medium: return 0.18
        case .high: return 0.26
        }
    }

    var outgoingOffsetFactor: Double {
        switch self {
        case .subtle: return 0.04
        case .medium: return 0.08
        case .high: return 0.12
        }
    }
}
private enum SwipeYawLevel: String, CaseIterable {
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .low: return "轻微"
        case .medium: return "标准"
        case .high: return "明显"
        }
    }

    var degrees: Double {
        switch self {
        case .low: return 8
        case .medium: return 14
        case .high: return 20
        }
    }
}

private enum SwipeGlossLevel: String, CaseIterable {
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .low: return "柔和"
        case .medium: return "标准"
        case .high: return "强烈"
        }
    }

    var strength: Double {
        switch self {
        case .low: return 0.22
        case .medium: return 0.36
        case .high: return 0.52
        }
    }
}
