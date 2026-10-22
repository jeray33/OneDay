import SwiftUI
import Combine
import Photos
import UIKit

struct PhotoPreviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: DayViewModel
    let namespace: Namespace.ID
    /// Host-driven fade for background + chrome during the open/close hero
    /// transition (0 while flying in/out, 1 when fully presented).
    var sessionOpacity: Double = 1
    /// Host-driven opacity of the photo card. 0 while the flight layer owns the
    /// photo, 1 once it has landed.
    var cardOpacity: Double = 1
    var isSessionOpen: Bool = true
    var cornerGeometry: (String) -> PhotoCornerGeometry?
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
    // Reuse page preloads without blanking the stationary footer on selection.
    @State private var previewPlaces: [String: String] = [:]
    @State private var livePhotoVisitID = UUID()
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var imageCategoryOverride: ImageCategoryOverride = .automatic
    @State private var toastText: String?
    @State private var toastID: UUID?
    @State private var deleteRestrictionWarned = false
    @GestureState private var dragGestureActive = false
    @State private var dragSequence = UUID()
    @State private var interactionPolicy = PreviewInteractionPolicy()
    @State private var interactionRecoveryID = UUID()
    @State private var dragCancellationTask: Task<Void, Never>?
    @State private var stagingTask: Task<Void, Never>?
    @State private var undoTask: Task<Void, Never>?
    @State private var flipTask: Task<Void, Never>?
    @State private var swipeHapticTask: Task<Void, Never>?

    init(model: DayViewModel, current: PhotoItem, namespace: Namespace.ID,
         sessionOpacity: Double = 1, cardOpacity: Double = 1, isSessionOpen: Bool = true,
         cornerGeometry: @escaping (String) -> PhotoCornerGeometry? = { _ in nil },
         onSelectionChanged: @escaping (String) -> Void = { _ in },
         onClose: @escaping (CGSize, CGFloat, String) -> Void = { _, _, _ in }) {
        self.model = model
        self.namespace = namespace
        self.sessionOpacity = sessionOpacity
        self.cardOpacity = cardOpacity
        self.isSessionOpen = isSessionOpen
        self.cornerGeometry = cornerGeometry
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

    /// Capabilities of the currently previewed photo; permissive when there is
    /// no selection (e.g. an empty day) so dismiss gestures keep working.
    private var currentItemCapabilities: SharedAssetPolicy {
        currentItem?.sharedCapabilities ?? .unrestricted
    }
    /// True while the previewed photo may not be deleted (e.g. shared by a
    /// friend): the up-swipe becomes a rubber band instead of staging.
    private var isDeleteRestricted: Bool {
        !currentItemCapabilities.canDelete
    }
    /// 0…1 opacity for the "cannot delete" hint, driven by the damped drag.
    private var deleteRestrictionHintProgress: Double {
        guard isDeleteRestricted else { return 0 }
        return min(max(-dragOffset.height, 0) / 64, 1)
    }

    private var dragProgress: CGFloat {
        min(max(dragOffset.height, 0) / 320, 1)
    }
    private var deleteProgress: CGFloat {
        guard !isDeleteRestricted else { return 0 }
        return min(max(-dragOffset.height, 0) / 280, 1)
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

    private var allowsLivePlayback: Bool {
        isSessionOpen && scenePhase == .active && !isClosing
            && !isZoomed && !isFlipActive && dragStartSelection == nil
            && !isVerticalDragLocked && !isStagingDelete && undoItemID == nil
            && albumItem == nil && editingItem == nil && !showAlbumConfig && !showPendingDelete
            && !isMutatingHidden
    }

    var body: some View {
        GeometryReader { geometry in
            previewContent(size: geometry.size)
        }
        .ignoresSafeArea()
    }

    private func previewContent(size: CGSize) -> some View {
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
                        onFlipBackRequest: { requestFlip(toBack: false) },
                        isSelected: selection == item.id,
                        livePhotoVisitID: livePhotoVisitID,
                        allowsLivePlayback: allowsLivePlayback && selection == item.id,
                        onPlaceResolved: { id, title in
                            previewPlaces[id] = title
                        },
                        interactionRecoveryID: interactionRecoveryID,
                        cornerGeometry: cornerGeometry(item.id)
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .opacity((isVerticalDragLocked ? 0 : 1) * cardOpacity)
            .allowsHitTesting(!isVerticalDragLocked && !isFlipActive && !isClosing)

            verticalDragOverlay
            undoRestoreOverlay

            // This layer stays outside TabView, so only the media pages slide.
            bottomInfo
        }
        // Keep the recognizer on a stable ancestor, not the page we hide and
        // disable while a vertical drag is in progress.
        .coordinateSpace(name: "previewInteraction")
        .simultaneousGesture(dismissDrag(in: size))
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .top) { deleteRestrictionHint }
        .overlay(alignment: .top) { toastView }
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
        .onChange(of: dragGestureActive) { _, active in
            guard !active, dragStartSelection != nil else { return }
            let sequence = dragSequence
            dragCancellationTask?.cancel()
            dragCancellationTask = Task { @MainActor in
                // Normal onEnded consumes the drag first. GestureState also
                // resets on cancellation, which has no onEnded callback.
                await Task.yield()
                guard !Task.isCancelled, sequence == dragSequence,
                      !dragGestureActive, dragStartSelection != nil else { return }
                resetDrag(animated: scenePhase == .active)
            }
        }
        .onChange(of: scenePhase) { _, _ in
            recoverFromInterruption()
        }
        .onDisappear {
            recoverFromInterruption(notifySelection: false)
        }
        .onChange(of: selection) {
            // A vertical dismiss drag pins `selection` back to its start every
            // frame; running the resets below then would zero `dragOffset` and
            // fight the live drag, making the card snap to full size and shake
            // (issues when dragging up/down then sideways). Skip entirely while
            // vertically locked.
            guard !isVerticalDragLocked else { return }
            livePhotoVisitID = UUID()
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
            if let item = currentItem {
                imageCategoryOverride = ImageClassificationStore.shared.override(for: item.asset.localIdentifier)
                Task { await OtherImageClassificationService.shared.classify([item.asset]) }
            }
            await updateDynamicBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageClassificationChanged).receive(on: RunLoop.main)) { _ in
            if let item = currentItem {
                imageCategoryOverride = ImageClassificationStore.shared.override(for: item.asset.localIdentifier)
            }
        }
    }

    private var bottomInfo: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let item = currentItem {
                PreviewInfoView(item: item, model: model,
                                place: item.location == nil ? nil : previewPlaces[item.id]) {
                    requestFlip(toBack: true)
                }
            }
        }
        .padding(.bottom, bottomSafeAreaInset() + 12)
        .ignoresSafeArea()
        .opacity(((isZoomed || isFlipActive) ? 0 : controlsOpacity) * sessionOpacity * cardOpacity)
        .animation(.easeInOut(duration: 0.16), value: isZoomed || isFlipActive)
        .allowsHitTesting(!isZoomed && !isFlipActive && !isClosing
                         && !isVerticalDragLocked && !isStagingDelete && undoItemID == nil
                         && controlsOpacity > 0.15 && sessionOpacity * cardOpacity > 0.15)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            if model.showAlbumTagBar {
                albumTagBar
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 24)))
            }
            bottomActionBar
        }
        .padding(.bottom, bottomSafeAreaInset() + 10)
        .offset(y: (isZoomed || isFlipActive) ? 18 : 0)
        .opacity(((isZoomed || isFlipActive) ? 0 : controlsOpacity) * sessionOpacity)
        .animation(.easeInOut(duration: 0.22), value: isZoomed || isFlipActive)
        .animation(PreviewTagBarTransition.animation(reduceMotion: reduceMotion), value: model.showAlbumTagBar)
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
        guard scenePhase == .active, isSessionOpen, !isClosing else { return }
        isClosing = true
        onClose(.zero, 1, selection)
    }

    private func dismissDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("previewInteraction"))
            .updating($dragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard scenePhase == .active, isSessionOpen, !isClosing,
                      !isZoomed, !isStagingDelete, !isFlipActive, undoItemID == nil,
                      PreviewInteractionPolicy.allowsStart(
                        y: value.startLocation.y, height: size.height,
                        topInset: topSafeAreaInset(), bottomInset: bottomSafeAreaInset()
                      ) else { return }
                if dragStartSelection == nil {
                    dragCancellationTask?.cancel()
                    dragSequence = UUID()
                    dragStartSelection = selection
                    deleteRestrictionWarned = false
                }
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
                    if isDeleteRestricted, t.height < 0 {
                        // Photos that must not be deleted (e.g. shared by a
                        // friend) rubber-band instead of staging: damped
                        // travel, no shrink, a warning buzz at the limit.
                        dragOffset = CGSize(width: t.width * 0.35,
                                            height: max(t.height * 0.32, -90))
                        if -dragOffset.height > 64, !deleteRestrictionWarned {
                            deleteRestrictionWarned = true
                            let feedback = UINotificationFeedbackGenerator()
                            feedback.prepare()
                            feedback.notificationOccurred(.warning)
                        }
                    } else {
                        dragOffset = CGSize(width: value.translation.width * 0.35,
                                            height: value.translation.height)
                    }
                    if let dragStartSelection, selection != dragStartSelection {
                        selection = dragStartSelection
                    }
                }
            }
            .onEnded { value in
                guard dragStartSelection != nil else { return }
                let startedSelection = dragStartSelection
                dragStartSelection = nil
                dragCancellationTask?.cancel()
                guard scenePhase == .active, isSessionOpen, !isClosing,
                      !isZoomed, !isStagingDelete, !isFlipActive, undoItemID == nil else {
                    resetDrag(animated: false)
                    return
                }
                let horizontalDistance = abs(value.translation.width)
                if observedHorizontalSwipe && horizontalDistance > 20 {
                    pendingSwipeSettleHaptic = true
                    swipeHapticTask?.cancel()
                    let generation = interactionPolicy.generation
                    swipeHapticTask = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 700_000_000) }
                        catch { return }
                        guard canCompleteInteraction(generation) else { return }
                        pendingSwipeSettleHaptic = false
                    }
                }
                observedHorizontalSwipe = false
                if isVerticalDragLocked, let startedSelection, selection != startedSelection {
                    selection = startedSelection
                }
                switch PreviewInteractionPolicy.endAction(
                    translation: value.translation, predicted: value.predictedEndTranslation,
                    verticalLocked: isVerticalDragLocked, canDelete: !isDeleteRestricted
                ) {
                case .browse:
                    onSelectionChanged(selection)
                case .restore:
                    resetDrag(animated: true)
                case .stage:
                    let generation = interactionPolicy.generation
                    stagingTask = Task { @MainActor in
                        await stageCurrentForDeletion(generation: generation)
                    }
                case .close:
                    if !pendingDeleteIDs.isEmpty {
                        resetDrag(animated: true)
                        showPendingDelete = true
                        return
                    }
                    guard !isClosing else { return }
                    isClosing = true
                    // Keep the dragged card shown (via verticalDragOverlay) so the
                    // flight layer takes over from its exact on-screen position.
                    onClose(dragOffset, activeScale, selection)
                }
            }
    }

    private func canCompleteInteraction(_ generation: UInt) -> Bool {
        !Task.isCancelled && interactionPolicy.canComplete(generation, isActive: scenePhase == .active)
    }

    private func resetDrag(animated: Bool, notifySelection: Bool = true) {
        if let id = verticalDragItemID, visibleItems.contains(where: { $0.id == id }) {
            selection = id
        }
        dragStartSelection = nil
        observedHorizontalSwipe = false
        isVerticalDragLocked = false
        verticalDragItemID = nil
        deleteRestrictionWarned = false
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
            dragOffset = .zero
            stagingDeleteScale = 1
        }
        if notifySelection, !isClosing, currentItem != nil {
            onSelectionChanged(selection)
        }
    }

    private func recoverFromInterruption(notifySelection: Bool = true) {
        interactionPolicy.invalidate()
        dragSequence = UUID()
        dragCancellationTask?.cancel()
        stagingTask?.cancel()
        undoTask?.cancel()
        flipTask?.cancel()
        swipeHapticTask?.cancel()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resetDrag(animated: false, notifySelection: notifySelection)
            pendingSwipeSettleHaptic = false
            isStagingDelete = false
            undoItemID = nil
            undoOffset = .zero
            undoScale = 1
            // flipAngle already stores the destination, not the presentation
            // angle. Settle there rather than leaving a transition lock.
            isFlipTransitioning = false
            interactionRecoveryID = UUID()
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
                    Button {
                        editingItem = item
                    } label: {
                        Label("编辑说明", systemImage: "pencil")
                    }
                    .disabled(!item.sharedCapabilities.canEditCaption)
                    Button {
                        albumItem = item
                    } label: {
                        Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(!item.sharedCapabilities.canEditAlbums)
                    if MediaFilter.supportsImageClassification(item.asset) {
                        Menu {
                            Picker("图片分类", selection: Binding(
                                get: { imageCategoryOverride },
                                set: { choice in
                                    imageCategoryOverride = choice
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
                    Divider()
                    Toggle(isOn: Binding(
                        get: { model.showAlbumTagBar },
                        set: { model.showAlbumTagBar = $0 }
                    )) {
                        Label("相簿标签栏", systemImage: "rectangle.stack")
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
                        .contentShape(.circle)
                }
                .menuStyle(.borderlessButton)
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

    /// Transient explanation for a blocked action (e.g. read-only shared photos).
    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { toastText = text }
        toastID = UUID()
    }

    @ViewBuilder
    private var toastView: some View {
        if let text = toastText {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, topSafeAreaInset() + 56)
                .opacity(sessionOpacity)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toastID) {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    withAnimation(.easeIn(duration: 0.25)) { toastText = nil }
                }
        }
    }

    /// Fades in while the user tries to up-swipe-delete a photo that cannot be
    /// deleted (e.g. shared by a friend), alongside the rubber-band drag.
    @ViewBuilder
    private var deleteRestrictionHint: some View {
        if deleteRestrictionHintProgress > 0.01 {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(currentItem?.isForeignShared == true
                     ? "他人共享的照片不能删除"
                     : "这张照片不能删除")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, topSafeAreaInset() + 56)
            .opacity(deleteRestrictionHintProgress * sessionOpacity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        if let item = currentItem {
            HStack {
                Button {
                    guard item.sharedCapabilities.canFavorite else {
                        showToast(item.isForeignShared
                                  ? "他人共享的照片不能收藏"
                                  : "这张照片不能收藏")
                        return
                    }
                    Task { await model.toggleFavorite(item) }
                } label: {
                    let fav = model.isFavorite(item)
                    let canFavorite = item.sharedCapabilities.canFavorite
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(fav ? Theme.accent : .black.opacity(canFavorite ? 1 : 0.35))
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
                isReadOnly: !currentItemCapabilities.canEditAlbums
                    || !currentItemCapabilities.canHide,
                onConfigure: { showAlbumConfig = true },
                onTapAlbum: { album in
                    guard let item = currentItem else { return }
                    let allowed = album.id == AlbumInfo.hiddenAlbumID
                        ? item.sharedCapabilities.canHide
                        : item.sharedCapabilities.canEditAlbums
                    guard allowed else {
                        showToast(item.isForeignShared
                                  ? "他人共享的照片不能归类或隐藏"
                                  : "这张照片不能归类或隐藏")
                        return
                    }
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
        let realAlbums = tagAlbums.filter { $0.id != AlbumInfo.hiddenAlbumID }
        membershipIDs = model.albumIDs(containing: item, among: realAlbums)
    }

    private func toggleCurrentPhoto(in album: AlbumInfo) async {
        if album.id == AlbumInfo.hiddenAlbumID {
            await hideCurrentItem()
            return
        }
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

    private func stageCurrentForDeletion(generation: UInt) async {
        guard canCompleteInteraction(generation), isSessionOpen, !isClosing,
              let item = currentItem, !isStagingDelete,
              item.sharedCapabilities.canDelete else { return }
        if pendingDeleteIDs.contains(item.id) {
            advanceAfterStaging(from: item.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = .zero }
            isVerticalDragLocked = false
            verticalDragItemID = nil
            return
        }
        isStagingDelete = true
        defer {
            if interactionPolicy.generation == generation, isStagingDelete {
                isStagingDelete = false
                resetDrag(animated: false)
            }
        }
        withAnimation(.easeIn(duration: 0.3)) {
            dragOffset = CGSize(width: dragOffset.width, height: -360)
            stagingDeleteScale = 0.08
        }
        do { try await Task.sleep(nanoseconds: 320_000_000) }
        catch { return }
        guard canCompleteInteraction(generation), selection == item.id else { return }
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
        // Backstop: never hand a photo the policy refuses to delete to the
        // library, whatever path staged it.
        let targetItems = pendingDeleteItems.filter {
            selectedIDs.contains($0.id) && $0.sharedCapabilities.canDelete
        }
        guard !targetItems.isEmpty else { return }
        let deletedIDs = Set(targetItems.map(\.id))
        do {
            try await PhotoActionService.shared.delete(targetItems.map(\.asset))
            model.removeItems(ids: deletedIDs)
            pendingDeleteIDs.removeAll { deletedIDs.contains($0) }
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
                onFlipBackRequest: { requestFlip(toBack: false) },
                cornerGeometry: cornerGeometry(item.id)
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
                onFlipBackRequest: {},
                cornerGeometry: cornerGeometry(item.id)
            )
            .opacity(cardOpacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func undoLastStaged() {
        guard scenePhase == .active, isSessionOpen, !isClosing,
              undoItemID == nil, !isStagingDelete,
              let lastID = pendingDeleteIDs.last,
              allItems.contains(where: { $0.id == lastID }) else { return }
        undoItemID = lastID
        undoOffset = CGSize(width: 0, height: -360)
        undoScale = 0.08
        withAnimation(.easeOut(duration: 0.4)) {
            undoOffset = .zero
            undoScale = 1
        }
        undoTask?.cancel()
        let generation = interactionPolicy.generation
        undoTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            guard canCompleteInteraction(generation) else { return }
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.prepare()
            feedback.impactOccurred(intensity: 0.7)
            pendingDeleteIDs.removeAll { $0 == lastID }
            selection = lastID
            undoItemID = nil
        }
    }

    private func requestFlip(toBack: Bool) {
        guard scenePhase == .active, isSessionOpen, !isClosing,
              !isStagingDelete, undoItemID == nil else { return }
        if toBack {
            guard !isFlippedToBack, !isFlipTransitioning, !isZoomed else { return }
        } else {
            guard (isFlippedToBack || isFlipTransitioning), !isFlipTransitioning else { return }
        }
        isFlipTransitioning = true
        withAnimation(.easeInOut(duration: 0.6)) {
            flipAngle = toBack ? 180 : 0
        }
        flipTask?.cancel()
        let generation = interactionPolicy.generation
        let itemID = selection
        flipTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 650_000_000) }
            catch { return }
            guard canCompleteInteraction(generation), selection == itemID else { return }
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
