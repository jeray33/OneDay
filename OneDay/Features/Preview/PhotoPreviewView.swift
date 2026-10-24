import SwiftUI
import Combine
import Photos
import UIKit

/// Per-frame drag presentation state for the preview: the live translation and
/// the staging shrink. A reference object, because drag frames must not
/// re-evaluate the host body or rebuild the page TabView — only the leaves
/// that read this state (the pinned drag overlay and the chrome fades) update
/// while a finger moves. Eligibility flags that flip once per interaction stay
/// plain `@State` on the host.
@MainActor @Observable
final class PreviewDragState {
    /// Damped translation of the active vertical drag.
    var offset: CGSize = .zero
    /// Extra shrink applied while the delete-staging animation runs.
    var stagingScale: CGFloat = 1
    /// Whether the previewed photo refuses deletion, captured when a drag
    /// starts; the guards below mirror the old per-drag checks.
    var isRestricted = false

    /// 0…1 progress of a pull-down (dismiss) drag.
    var dragProgress: CGFloat { min(max(offset.height, 0) / 320, 1) }
    /// 0…1 progress of a pull-up (delete) drag.
    var deleteProgress: CGFloat {
        guard !isRestricted else { return 0 }
        return min(max(-offset.height, 0) / 280, 1)
    }
    /// 0…1 fade of the cannot-delete hint.
    var restrictedHintProgress: CGFloat {
        guard isRestricted else { return 0 }
        return min(max(-offset.height, 0) / 64, 1)
    }
    /// Chrome (bars, info) fade driven by either drag direction.
    var controlsOpacity: Double {
        let progress = max(dragProgress, deleteProgress)
        return Double(max(0, 1 - progress * 2))
    }
    /// Card scale combining both drag directions with the staging shrink.
    var scale: CGFloat {
        let base = 1 - dragProgress * 0.18 - deleteProgress * 0.45
        return max(0.08, base) * stagingScale
    }
}

/// Derived item collections for one preview session, rebuilt exactly when the
/// day's items or the staged deletions change — never per frame or per body
/// evaluation — so the host's reads (current item, neighbors, staged items)
/// stay O(1) instead of rescanning the day.
@MainActor @Observable
final class PreviewItemsIndex {
    private(set) var visible: [PhotoItem] = []
    private(set) var visibleByID: [String: PhotoItem] = [:]
    private(set) var visibleIndexByID: [String: Int] = [:]
    private(set) var allByID: [String: PhotoItem] = [:]

    init(allItems: [PhotoItem] = [], pendingDeleteIDs: [String] = []) {
        rebuild(allItems: allItems, pendingDeleteIDs: pendingDeleteIDs)
    }

    func rebuild(allItems: [PhotoItem], pendingDeleteIDs: [String]) {
        let pending = Set(pendingDeleteIDs)
        var visible: [PhotoItem] = []
        var visibleByID: [String: PhotoItem] = [:]
        var visibleIndexByID: [String: Int] = [:]
        var allByID: [String: PhotoItem] = [:]
        for item in allItems {
            allByID[item.id] = item
            guard !pending.contains(item.id) else { continue }
            visibleIndexByID[item.id] = visible.count
            visibleByID[item.id] = item
            visible.append(item)
        }
        self.visible = visible
        self.visibleByID = visibleByID
        self.visibleIndexByID = visibleIndexByID
        self.allByID = allByID
    }
}

/// Fades the preview backdrop as the photo is pulled down. Reading the drag
/// state here, rather than in the host body, keeps drag frames from
/// re-evaluating the host or the page TabView.
private struct DragDimmedBackdrop<Content: View>: View {
    let drag: PreviewDragState
    let sessionOpacity: Double
    let content: Content

    var body: some View {
        content.opacity(sessionOpacity * Double(1 - drag.dragProgress))
    }
}

/// Hosts a piece of preview chrome (top bar, bottom info, action controls)
/// whose visibility follows the live drag. As with the backdrop, reading the
/// drag state here keeps drag frames off the host body and the page TabView.
private struct DragFadedChrome<Content: View>: View {
    let drag: PreviewDragState
    /// Chrome is fully hidden regardless of drag (zoom or flip active).
    let hidden: Bool
    /// The non-drag visibility factor: sessionOpacity (× cardOpacity).
    let visibleOpacity: Double
    let fadeDuration: Double
    /// Optional hit-test predicate over the live drag state; the caller bakes
    /// its non-drag conditions into the returned Bool. Nil leaves hit testing
    /// untouched.
    var hitTest: ((PreviewDragState) -> Bool)? = nil
    let content: Content

    var body: some View {
        let faded = content
            .opacity((hidden ? 0 : drag.controlsOpacity) * visibleOpacity)
            .animation(.easeInOut(duration: fadeDuration), value: hidden)
        if let hitTest {
            faded.allowsHitTesting(hitTest(drag))
        } else {
            faded
        }
    }
}

/// The cannot-delete hint, fading in with the damped up-drag. Reads the drag
/// state directly so the per-frame fade never touches the host body.
private struct DeleteRestrictionHintView: View {
    let drag: PreviewDragState
    let sessionOpacity: Double
    let color: Color
    let topPadding: CGFloat
    let icon: String
    let text: String

    var body: some View {
        if drag.restrictedHintProgress > 0.01 {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, topPadding)
            .opacity(drag.restrictedHintProgress * sessionOpacity)
            .allowsHitTesting(false)
        }
    }
}

/// The pinned page shown while a vertical drag is active: the only
/// page-sized view that follows the drag translation and scale frame by
/// frame. The TabView stays hidden for the duration.
private struct VerticalDragOverlayPage: View {
    let drag: PreviewDragState
    let item: PhotoItem
    let model: DayViewModel
    let cardOpacity: Double
    let isZoomed: Bool
    let flipAngle: Double
    let chromeHidden: Bool
    let swipeEffectConfig: SwipePreviewEffectConfig
    let cornerGeometry: PhotoCornerGeometry?
    let onZoomChanged: (Bool) -> Void
    let onFlipRequest: () -> Void
    let onFlipBackRequest: () -> Void

    var body: some View {
        PreviewPageView(
            item: item,
            model: model,
            onZoomChanged: onZoomChanged,
            photoOffsetX: drag.offset.width,
            photoOffsetY: drag.offset.height,
            photoScale: drag.scale,
            infoOpacity: chromeHidden ? 0 : drag.controlsOpacity,
            isZoomed: isZoomed,
            flipAngle: flipAngle,
            swipeEffectConfig: swipeEffectConfig,
            onFlipRequest: onFlipRequest,
            onFlipBackRequest: onFlipBackRequest,
            cornerGeometry: cornerGeometry)
        .opacity(cardOpacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

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
    @AppStorage(PreviewBackground.storageKey) private var savedBackground = PreviewBackground.day.rawValue

    @State private var selection: String
    /// Derived item collections, rebuilt only when the day's items or the
    /// staged deletions change; the reads below stay O(1).
    @State private var itemsIndex: PreviewItemsIndex
    // Reuse page preloads without blanking the stationary footer on selection.
    @State private var previewPlaces: [String: String] = [:]
    @State private var livePhotoVisitID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @State private var dragState = PreviewDragState()
    @State private var isZoomed = false
    @State private var sharingContent: PreparedPhotoShare?
    @State private var sharePreparationID: UUID?
    @State private var sharePreparationTask: Task<Void, Never>?
    @State private var dynamicGradient = BackCoverGradient.gradient()
    @State private var showAlbumConfig = false
    @State private var tagAlbums: [AlbumInfo] = []
    @State private var membershipIDs: Set<String> = []
    @State private var isMutatingAlbum = false
    @State private var isMutatingHidden = false
    @State private var pendingDeleteIDs: [String] = []
    @State private var showPendingDelete = false
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
    @State private var membershipTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var stagingTask: Task<Void, Never>?
    @State private var undoTask: Task<Void, Never>?
    @State private var flipTask: Task<Void, Never>?
    @State private var swipeHapticTask: Task<Void, Never>?
    @AppStorage("OneDay.didExplainPhotoRotation") private var didExplainPhotoRotation = false
    @State private var rotationConfirmationItem: PhotoItem?
    @State private var showRotationConfirmation = false
    @State private var rotationTransitionIDs: Set<String> = []
    @State private var isPreviewVisible = false
    @State private var videoPlayback = PreviewVideoPlayer()
    @State private var centeredVideoID: String?
    @State private var videoRetryID = UUID()

    private var isRotationTransitioning: Bool { rotationTransitionIDs.contains(selection) }
    private var isSharing: Bool { sharingContent != nil || sharePreparationID != nil }
    private var showsRotationControls: Bool {
        scenePhase == .active && isSessionOpen && !isClosing
            && sessionOpacity > 0.99 && cardOpacity > 0.99
            && !isZoomed && !isFlipActive && dragStartSelection == nil
            && !isVerticalDragLocked && !isStagingDelete && undoItemID == nil
            && !isSharing && !showAlbumConfig && !showPendingDelete
            && !isMutatingHidden && !isMutatingAlbum
    }
    private var allowsRotationControls: Bool { showsRotationControls && !isZoomed }

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
        // The host is recreated during hero animations. Seed in constant time;
        // build the full session index once on appearance.
        _itemsIndex = State(initialValue: PreviewItemsIndex(allItems: [current]))
    }

    private var allItems: [PhotoItem] { model.allItems }
    /// The derived collections live in `itemsIndex` (rebuilt only when the
    /// day's items or the staged deletions change), so these reads stay O(1).
    private var visibleItems: [PhotoItem] { itemsIndex.visible }
    private var currentItem: PhotoItem? { itemsIndex.visibleByID[selection] }
    private var pendingDeleteItems: [PhotoItem] {
        pendingDeleteIDs.compactMap { itemsIndex.allByID[$0] }
    }
    private var pendingDeleteLastItem: PhotoItem? {
        pendingDeleteIDs.last.flatMap { itemsIndex.allByID[$0] }
    }

    /// Capabilities of the currently previewed photo; permissive when there is
    /// no selection (e.g. an empty day) so dismiss gestures keep working.
    private var currentItemCapabilities: SharedAssetPolicy {
        currentItem?.sharedCapabilities ?? .unrestricted
    }
    /// True while the previewed photo may not be deleted (e.g. shared by a
    /// friend): the up-swipe becomes a rubber band instead of staging.
    private var isDeleteRestricted: Bool {
        !currentItemCapabilities.canDelete || PhotoRotationService.shared.isSaving(selection)
    }
    // The drag-driven progress, scale and chrome fade now live on `dragState`
    // (see `PreviewDragState` above), read only by the drag leaf views.
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
            && !isSharing && !showAlbumConfig && !showPendingDelete
            && !isMutatingHidden
    }

    private var showsVideoControls: Bool {
        currentItem?.isVideo == true && isSessionOpen && scenePhase == .active && !isClosing
            && sessionOpacity > 0.99 && cardOpacity > 0.99
            && !isFlipActive && dragStartSelection == nil && !isVerticalDragLocked
            && !isStagingDelete && undoItemID == nil
            && !isSharing && !showAlbumConfig && !showPendingDelete
            && !isMutatingHidden && !isMutatingAlbum
    }

    private var allowsVideoPlayback: Bool {
        showsVideoControls && centeredVideoID == selection
            && videoPlayback.contentVersion == currentItem?.contentVersion
    }

    private var videoRequestID: String {
        "\(currentItem?.contentVersion ?? "")|\(scenePhase == .active && isSessionOpen && !isClosing)|\(videoRetryID)"
    }

    private var previewBackground: PreviewBackground {
        PreviewBackground(savedValue: savedBackground)
    }

    private var previewColorScheme: ColorScheme {
        previewBackground == .immersive ? .dark : model.pageColorScheme
    }

    private var controlsColor: Color {
        previewBackground == .immersive ? .white : .black
    }

    private var backgroundRequestID: String {
        "\(previewBackground.rawValue)|\(currentItem?.contentVersion ?? "")"
    }

    var body: some View {
        GeometryReader { geometry in
            previewContent(size: geometry.size)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, previewColorScheme)
    }

    private var previewBackdrop: some View {
        Group {
            if previewBackground == .immersive {
                LinearGradient(
                    gradient: dynamicGradient,
                    startPoint: .top, endPoint: .bottom)
            } else {
                model.pageBackgroundColor
            }
        }
        .ignoresSafeArea()
    }

    private func previewPresentation(size: CGSize) -> some View {
        ZStack {
            DragDimmedBackdrop(drag: dragState, sessionOpacity: sessionOpacity, content: previewBackdrop)

            TabView(selection: $selection) {
                ForEach(visibleItems) { item in
                    PreviewPageView(
                        item: item,
                        model: model,
                        onZoomChanged: { isZoomed = $0 },
                        photoOffsetX: 0,
                        photoOffsetY: 0,
                        photoScale: 1,
                        // A vertical drag hides the whole TabView (its opacity
                        // below) and the pinned overlay owns the live fade, so
                        // pages never need a drag-driven value here.
                        infoOpacity: (isZoomed || isFlipActive) ? 0 : 1,
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
                        cornerGeometry: cornerGeometry(item.id),
                        allowsRotationControls: allowsRotationControls && selection == item.id,
                        showsRotationControls: showsRotationControls && selection == item.id,
                        onRotate: { requestRotation(item) },
                        onRotationTransitionChanged: { id, active in
                            if active { rotationTransitionIDs.insert(id) }
                            else { rotationTransitionIDs.remove(id) }
                        },
                        videoPlayer: selection == item.id && videoPlayback.contentVersion == item.contentVersion
                            ? videoPlayback.player : nil,
                        onVideoVisibilityChanged: { id, centered in
                            if centered { centeredVideoID = id }
                            else if centeredVideoID == id { centeredVideoID = nil }
                        },
                        onVideoTap: {
                            guard selection == item.id, allowsVideoPlayback else { return }
                            videoPlayback.togglePlayback()
                        },
                        videoPlaybackActionLabel: videoPlayback.isPlaying ? "暂停视频" : "播放视频",
                        isVideoPlaying: videoPlayback.isPlaying,
                        showsVideoPlaybackIcon: allowsVideoPlayback && videoPlayback.canPlay
                            && !videoPlayback.isScrubbing
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
        .overlay(alignment: .top) {
            DragFadedChrome(drag: dragState,
                            hidden: isZoomed || isFlipActive,
                            visibleOpacity: sessionOpacity,
                            fadeDuration: 0.22,
                            content: topBar)
        }
        .overlay(alignment: .top) {
            DeleteRestrictionHintView(
                drag: dragState,
                sessionOpacity: sessionOpacity,
                color: controlsColor,
                topPadding: topSafeAreaInset() + 56,
                icon: PhotoRotationService.shared.isSaving(selection)
                    ? "arrow.trianglehead.2.clockwise" : "person.2.fill",
                text: PhotoRotationService.shared.isSaving(selection)
                    ? "旋转保存中，请稍后再删除"
                    : (currentItem?.isForeignShared == true ? "他人共享的照片不能删除" : "这张照片不能删除"))
        }
        .overlay(alignment: .top) { toastView }
        .overlay(alignment: .bottom) { bottomControls }
        // A sibling of TabView and of its dismiss recognizer: a slider drag
        // cannot become paging, dismissal, deletion, or card zoom.
        .overlay(alignment: .bottom) { videoControls }
        .statusBarHidden()
        .sheet(item: $sharingContent) { content in
            PhotoShareSheet(content: content)
        }
        .sheet(isPresented: $showAlbumConfig) {
            AlbumConfigSheet(model: model) {
                refreshTagAlbums()
            }
            .environment(\.colorScheme, model.pageColorScheme)
        }
        .sheet(isPresented: $showPendingDelete) {
            PendingDeleteSheet(
                items: pendingDeleteItems,
                onCancel: {
                    pendingDeleteIDs.removeAll()
                    rebuildItemsIndex()
                    showPendingDelete = false
                    performDismiss()
                },
                onConfirm: { selectedIDs in
                    Task { await confirmPendingDelete(selectedIDs: selectedIDs) }
                }
            )
            .environment(\.colorScheme, model.pageColorScheme)
        }
        .alert("将旋转保存到照片图库？", isPresented: $showRotationConfirmation) {
            Button("取消", role: .cancel) { rotationConfirmationItem = nil }
            Button("旋转并保存") {
                didExplainPhotoRotation = true
                if let item = rotationConfirmationItem, item.id == selection {
                    startRotation(item)
                }
                rotationConfirmationItem = nil
            }
        } message: {
            Text("每次顺时针旋转 90°，直接更新原照片，不生成副本。更改会随 iCloud 照片同步；原始内容仍可在系统“照片”中恢复。")
        }
    }

    private func previewLifecycle(size: CGSize) -> some View {
        previewPresentation(size: size)
        .onAppear {
            isPreviewVisible = true
            rebuildItemsIndex()
            onSelectionChanged(selection)
            refreshTagAlbums()
            prefetchNeighborPages(size: size)
            ensureValidSelectionAfterFiltering()
            PhotoRotationService.shared.reconcilePendingEdits { model.refreshEditedAsset($0) }
            showPendingRotationFailure()
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
            if scenePhase != .active { videoPlayback.pause() }
            recoverFromInterruption()
            if scenePhase != .active { cancelSharePreparation() }
            if scenePhase == .active {
                PhotoRotationService.shared.reconcilePendingEdits { model.refreshEditedAsset($0) }
            }
        }
        .onDisappear {
            videoPlayback.close()
            isPreviewVisible = false
            cancelSharePreparation()
            membershipTask?.cancel()
            prefetchTask?.cancel()
            recoverFromInterruption(notifySelection: false)
        }
        .onChange(of: currentItem?.contentVersion) { _, _ in
            videoPlayback.pause()
            cancelSharePreparation()
            refreshMembership()
        }
    }

    private func previewContent(size: CGSize) -> some View {
        previewLifecycle(size: size)
        .onChange(of: selection) {
            // A vertical dismiss drag pins `selection` back to its start every
            // frame; running the resets below then would zero the drag state
            // and fight the live drag, making the card snap to full size and
            // shake (issues when dragging up/down then sideways). Skip
            // entirely while vertically locked.
            guard !isVerticalDragLocked else { return }
            livePhotoVisitID = UUID()
            // Defer committing the page to the grid until a drag settles, so
            // transient TabView paging during a fast flick doesn't churn it.
            if dragStartSelection == nil {
                onSelectionChanged(selection)
            }
            isZoomed = false
            dragState.offset = .zero
            flipAngle = 0
            isFlipTransitioning = false
            if pendingSwipeSettleHaptic {
                pendingSwipeSettleHaptic = false
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.prepare()
                feedback.impactOccurred(intensity: 0.55)
            }
            refreshMembership()
            prefetchNeighborPages(size: size)
            showPendingRotationFailure()
        }
        .onChange(of: model.itemsRevision) {
            rebuildItemsIndex()
            ensureValidSelectionAfterFiltering()
            prefetchNeighborPages(size: size)
        }
        .onChange(of: size) {
            prefetchNeighborPages(size: size)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isFlippedToBack {
                requestFlip(toBack: false)
            }
        }
        .task(id: currentItem?.contentVersion) {
            if let item = currentItem {
                imageCategoryOverride = ImageClassificationStore.shared.override(for: item.asset.localIdentifier)
                Task { await OtherImageClassificationService.shared.classify([item.asset]) }
            }
        }
        .task(id: backgroundRequestID) {
            await updatePreviewGradient()
        }
        .task(id: videoRequestID) {
            guard scenePhase == .active, isSessionOpen, !isClosing else { return }
            let item = currentItem
            await videoPlayback.load(
                asset: item?.isVideo == true ? item?.asset : nil,
                version: item?.isVideo == true ? item?.contentVersion : nil
            )
        }
        .onChange(of: allowsVideoPlayback, initial: true) { _, permitted in
            videoPlayback.permit(permitted)
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageClassificationChanged).receive(on: RunLoop.main)) { _ in
            if let item = currentItem {
                imageCategoryOverride = ImageClassificationStore.shared.override(for: item.asset.localIdentifier)
            }
        }
    }

    private func requestShare(_ item: PhotoItem) {
        guard !isSharing, scenePhase == .active, isSessionOpen, !isClosing,
              item.id == selection, !PhotoRotationService.shared.isSaving(item.id),
              !isRotationTransitioning else { return }
        let requestID = UUID()
        sharePreparationID = requestID
        toastText = nil
        sharePreparationTask = Task { @MainActor in
            defer {
                if sharePreparationID == requestID {
                    sharePreparationID = nil
                    sharePreparationTask = nil
                }
            }
            do {
                let content = try await PreparedPhotoShare.prepare(asset: item.asset)
                guard !Task.isCancelled, sharePreparationID == requestID,
                      isPreviewVisible, scenePhase == .active, isSessionOpen, !isClosing,
                      currentItem?.contentVersion == item.contentVersion,
                      !isZoomed, !isFlipActive, dragStartSelection == nil,
                      !isVerticalDragLocked, !isStagingDelete, undoItemID == nil,
                      !showAlbumConfig, !showPendingDelete else { return }
                sharingContent = content
            } catch {
                guard !Task.isCancelled, sharePreparationID == requestID,
                      isPreviewVisible, scenePhase == .active, !isClosing,
                      selection == item.id else { return }
                showToast(error.localizedDescription)
            }
        }
    }

    private func cancelSharePreparation() {
        sharePreparationID = nil
        sharePreparationTask?.cancel()
        sharePreparationTask = nil
    }

    private func requestRotation(_ item: PhotoItem) {
        guard allowsRotationControls, !isRotationTransitioning,
              item.id == selection, !pendingDeleteIDs.contains(item.id),
              PhotoRotationService.shared.canRotate(item),
              !PhotoRotationService.shared.isSaving(item.id) else { return }
        if didExplainPhotoRotation {
            startRotation(item)
        } else {
            rotationConfirmationItem = item
            showRotationConfirmation = true
        }
    }

    private func startRotation(_ item: PhotoItem) {
        guard allowsRotationControls, item.id == selection, !isRotationTransitioning else { return }
        PhotoRotationService.shared.start(item) { asset in
            // Always refresh the edited asset, even after browsing / closing.
            model.refreshEditedAsset(asset, clockwiseRotation: true)
        } onFailure: { error in
            if selection == item.id, !isClosing, isPreviewVisible {
                showToast(PhotoRotationService.shared.takeFailure(for: item.id) ?? error.localizedDescription)
            }
        }
    }

    private func showPendingRotationFailure() {
        if let message = PhotoRotationService.shared.takeFailure(for: selection) {
            showToast(message)
        }
    }

    private var bottomInfo: some View {
        DragFadedChrome(
            drag: dragState,
            hidden: isZoomed || isFlipActive,
            visibleOpacity: sessionOpacity * cardOpacity,
            fadeDuration: 0.16,
            hitTest: { drag in
                !isZoomed && !isFlipActive && !isClosing
                    && !isVerticalDragLocked && !isStagingDelete && undoItemID == nil
                    && drag.controlsOpacity > 0.15 && sessionOpacity * cardOpacity > 0.15
            },
            content: VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let item = currentItem {
                    PreviewInfoView(item: item,
                                    place: item.location == nil ? nil : previewPlaces[item.id]) {
                        requestFlip(toBack: true)
                    }
                }
            }
            .padding(.bottom, bottomSafeAreaInset() + 12)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.16), value: isZoomed || isFlipActive))
    }

    private var bottomControls: some View {
        DragFadedChrome(
            drag: dragState,
            hidden: isZoomed || isFlipActive,
            visibleOpacity: sessionOpacity,
            fadeDuration: 0.22,
            hitTest: { drag in
                !(isZoomed || isFlipActive)
                    && max(drag.dragProgress, drag.deleteProgress) < 0.15
                    && !isMutatingAlbum && !isMutatingHidden && !isStagingDelete
            },
            content: VStack(spacing: 8) {
                if model.showAlbumTagBar {
                    albumTagBar
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 24)))
                }
                bottomActionBar
            }
            .padding(.bottom, bottomSafeAreaInset() + 10)
            .offset(y: (isZoomed || isFlipActive) ? 18 : 0)
            .animation(.easeInOut(duration: 0.22), value: isZoomed || isFlipActive)
            .animation(PreviewTagBarTransition.animation(reduceMotion: reduceMotion), value: model.showAlbumTagBar))
    }

    @ViewBuilder
    private var videoControls: some View {
        if currentItem?.isVideo == true {
            let actionHeight: CGFloat = isZoomed ? 0 : 40 + (model.showAlbumTagBar ? 36 : 0) + 12
            PreviewVideoControls(playback: videoPlayback) {
                videoRetryID = UUID()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomSafeAreaInset() + 10 + actionHeight)
            .opacity(showsVideoControls ? 1 : 0)
            .allowsHitTesting(showsVideoControls)
        }
    }

    private func updatePreviewGradient() async {
        let requestID = backgroundRequestID
        guard previewBackground == .immersive, let item = currentItem else { return }
        let gradient = await model.previewGradient(for: item)
        // Rapid paging, edits, or changing the menu must not apply an old color.
        guard !Task.isCancelled, backgroundRequestID == requestID else { return }
        // Keep the displayed gradient while loading, then blend directly to
        // the new photo instead of flashing the neutral fallback in between.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            dynamicGradient = gradient
        }
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
        guard scenePhase == .active, isSessionOpen, !isClosing, !isRotationTransitioning else { return }
        isClosing = true
        onClose(.zero, 1, selection)
    }

    private func dismissDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named("previewInteraction"))
            .updating($dragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard scenePhase == .active, isSessionOpen, !isClosing,
                      !isZoomed, !isStagingDelete, !isFlipActive, !isRotationTransitioning, undoItemID == nil,
                      PreviewInteractionPolicy.allowsStart(
                        y: value.startLocation.y, height: size.height,
                        topInset: topSafeAreaInset(), bottomInset: bottomSafeAreaInset()
                      ) else { return }
                if dragStartSelection == nil {
                    dragCancellationTask?.cancel()
                    dragSequence = UUID()
                    dragStartSelection = selection
                    deleteRestrictionWarned = false
                    dragState.isRestricted = isDeleteRestricted
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
                    dragState.isRestricted = isDeleteRestricted
                    if isDeleteRestricted, t.height < 0 {
                        // Photos that must not be deleted (e.g. shared by a
                        // friend) rubber-band instead of staging: damped
                        // travel, no shrink, a warning buzz at the limit.
                        dragState.offset = CGSize(width: t.width * 0.35,
                                                  height: max(t.height * 0.32, -90))
                        if -dragState.offset.height > 64, !deleteRestrictionWarned {
                            deleteRestrictionWarned = true
                            let feedback = UINotificationFeedbackGenerator()
                            feedback.prepare()
                            feedback.notificationOccurred(.warning)
                        }
                    } else {
                        dragState.offset = CGSize(width: value.translation.width * 0.35,
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
                    onClose(dragState.offset, dragState.scale, selection)
                }
            }
    }

    private func canCompleteInteraction(_ generation: UInt) -> Bool {
        !Task.isCancelled && interactionPolicy.canComplete(generation, isActive: scenePhase == .active)
    }

    private func resetDrag(animated: Bool, notifySelection: Bool = true) {
        if let id = verticalDragItemID, itemsIndex.visibleByID[id] != nil {
            selection = id
        }
        dragStartSelection = nil
        observedHorizontalSwipe = false
        isVerticalDragLocked = false
        verticalDragItemID = nil
        deleteRestrictionWarned = false
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
            dragState.offset = .zero
            dragState.stagingScale = 1
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
                        requestShare(item)
                    } label: {
                        Label("共享", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isSharing || PhotoRotationService.shared.isSaving(item.id) || rotationTransitionIDs.contains(item.id))
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
                    Menu("背景") {
                        Picker("背景", selection: Binding(
                            get: { previewBackground },
                            set: { savedBackground = $0.rawValue }
                        )) {
                            ForEach(PreviewBackground.allCases) { background in
                                Text(background.label).tag(background)
                            }
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
                        .contentShape(.circle)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeAreaInset() + 8)
        .offset(y: (isZoomed || isFlipActive) ? -14 : 0)
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
            .foregroundStyle(controlsColor)
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
                .foregroundStyle(controlsColor)
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
                        .foregroundStyle(fav ? Theme.accent : controlsColor.opacity(canFavorite ? 1 : 0.35))
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
                            .foregroundStyle(controlsColor)
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
                        .foregroundStyle(controlsColor)
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
        membershipTask?.cancel()
        membershipIDs = []
        guard let item = currentItem else {
            return
        }
        let id = item.id
        let version = item.contentVersion
        let asset = item.asset
        let albumIDs = tagAlbums.map(\.id).filter { $0 != AlbumInfo.hiddenAlbumID }
        let service = PhotoActionService.shared
        membershipTask = Task { @MainActor in
            let query = Task.detached(priority: .userInitiated) {
                service.albumIDs(containing: asset, among: albumIDs)
            }
            let result = await withTaskCancellationHandler {
                await query.value
            } onCancel: {
                query.cancel()
            }
            guard !Task.isCancelled, isPreviewVisible, selection == id,
                  currentItem?.contentVersion == version else { return }
            membershipIDs = result
        }
    }

    private func rebuildItemsIndex() {
        itemsIndex.rebuild(allItems: allItems, pendingDeleteIDs: pendingDeleteIDs)
    }

    private func prefetchNeighborPages(size: CGSize) {
        prefetchTask?.cancel()
        guard let index = itemsIndex.visibleIndexByID[selection], !visibleItems.isEmpty else { return }
        let assets = (max(0, index - 2)...min(visibleItems.count - 1, index + 2))
            .filter { $0 != index }
            .map { visibleItems[$0].asset }
        let scale = UIScreen.main.scale
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        prefetchTask = Task {
            await ImageLoader.shared.preload(assets: assets, targetSize: target)
        }
    }

    private func toggleCurrentPhoto(in album: AlbumInfo) async {
        if album.id == AlbumInfo.hiddenAlbumID {
            await hideCurrentItem()
            return
        }
        guard !isMutatingAlbum, let item = currentItem else { return }
        isMutatingAlbum = true
        membershipTask?.cancel()
        defer {
            isMutatingAlbum = false
            refreshMembership()
        }

        if membershipIDs.contains(album.id) {
            let ok = await model.removeFromAlbum(album, item: item)
            guard ok, selection == item.id else { return }
            membershipIDs.remove(album.id)
        } else {
            let ok = await model.addToAlbum(album, item: item)
            guard ok, selection == item.id else { return }
            membershipIDs.insert(album.id)
            advanceToNextPhoto()
        }
    }

    private func advanceToNextPhoto() {
        guard let idx = itemsIndex.visibleIndexByID[selection],
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
              item.sharedCapabilities.canDelete, !PhotoRotationService.shared.isSaving(item.id) else { return }
        if pendingDeleteIDs.contains(item.id) {
            advanceAfterStaging(from: item.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragState.offset = .zero }
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
            dragState.offset = CGSize(width: dragState.offset.width, height: -360)
            dragState.stagingScale = 0.08
        }
        do { try await Task.sleep(nanoseconds: 320_000_000) }
        catch { return }
        guard canCompleteInteraction(generation), selection == item.id else { return }
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.7)
        pendingDeleteIDs.append(item.id)
        rebuildItemsIndex()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            dragState.offset = .zero
            dragState.stagingScale = 1
        }
        advanceAfterStaging(from: item.id)
        isStagingDelete = false
        isVerticalDragLocked = false
        verticalDragItemID = nil
    }

    private func advanceAfterStaging(from currentID: String) {
        let ids = model.gridItemIDs
        guard let currentIndex = ids.firstIndex(of: currentID) else { return }
        let targetID = ids[(currentIndex + 1)...].first { itemsIndex.visibleByID[$0] != nil }
            ?? ids[..<currentIndex].last { itemsIndex.visibleByID[$0] != nil }
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
                && !PhotoRotationService.shared.isSaving($0.id)
        }
        guard !targetItems.isEmpty else { return }
        let deletedIDs = Set(targetItems.map(\.id))
        do {
            try await PhotoActionService.shared.delete(targetItems.map(\.asset))
            model.removeItems(ids: deletedIDs)
            pendingDeleteIDs.removeAll { deletedIDs.contains($0) }
            rebuildItemsIndex()
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
        if itemsIndex.visibleByID[selection] == nil {
            selection = visibleItems[0].id
        }
    }

    @ViewBuilder
    private var verticalDragOverlay: some View {
        if isVerticalDragLocked,
           let lockedID = verticalDragItemID,
           let item = itemsIndex.visibleByID[lockedID] {
            VerticalDragOverlayPage(
                drag: dragState,
                item: item,
                model: model,
                cardOpacity: cardOpacity,
                isZoomed: isZoomed,
                flipAngle: flipAngle,
                chromeHidden: isZoomed || isFlipActive,
                swipeEffectConfig: swipeEffectConfig,
                cornerGeometry: cornerGeometry(item.id),
                onZoomChanged: { isZoomed = $0 },
                onFlipRequest: { requestFlip(toBack: true) },
                onFlipBackRequest: { requestFlip(toBack: false) })
        }
    }

    /// Reverse of the staging animation: the last staged photo flies back down
    /// from the top-shrunken position to its resting state.
    @ViewBuilder
    private var undoRestoreOverlay: some View {
        if let undoID = undoItemID,
           let item = itemsIndex.allByID[undoID] {
            PreviewPageView(
                item: item,
                model: model,
                onZoomChanged: { _ in },
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
              itemsIndex.allByID[lastID] != nil else { return }
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
            rebuildItemsIndex()
            selection = lastID
            undoItemID = nil
        }
    }

    private func requestFlip(toBack: Bool) {
        guard scenePhase == .active, isSessionOpen, !isClosing,
              !isStagingDelete, !isRotationTransitioning, undoItemID == nil else { return }
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
