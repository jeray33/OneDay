import SwiftUI
import Combine
import Photos
import UIKit
import CoreHaptics

struct RootView: View {
    private enum Phase: Equatable {
        case home
        case day
    }

    @State private var phase: Phase = .home
    @State private var dayModel: DayViewModel?
    @State private var navigationDays: [Date] = []
    @State private var navigationDaysLoaded = false
    @State private var navigationDaysLoading = false
    @State private var tunnelLayers: [TunnelLayer] = []
    @State private var rewindCandidateIndex: RewindCandidateIndex?
    @State private var tunnelSelections: [TunnelDaySelection] = []
    @State private var tunnelPreparationTask: Task<Void, Never>?
    @State private var tunnelUpdateTask: Task<Void, Never>?
    @State private var tunnelUpdateID = UUID()
    @State private var tunnelInteractionLocked = false
    @State private var tunnelClassificationRevision = 0
    @State private var tunnelStartDate: Date?
    @State private var rewindHomeID = UUID()
    @State private var rewindPreparationID = UUID()
    @State private var tunnelOpeningProgress = 0.0
    @State private var tunnelOpeningActive = true
    @State private var navLoading = false
    @State private var historyEntries: [TodayInHistoryEntry] = []
    @State private var historyLoading = false
    @State private var historyReferenceDay: Date?
    @State private var historyPreparationID = UUID()
    @State private var historyTask: Task<Void, Never>?
    @State private var historyCache: [Date: [TodayInHistoryEntry]] = [:]
    @State private var dayNavigationRequestID = UUID()
    @State private var sourceRefreshRequestID = UUID()
    @State private var tunnelNeedsUpdate = false
    @State private var showPermissionAlert = false
    @State private var showEmptyAlert = false
    @State private var dayFromTunnel = false
    @State private var hapticEngine: CHHapticEngine?
    @Namespace private var dateNamespace
    @AppStorage("OneDay.tunnelPhotoScale") private var tunnelPhotoScaleRaw = TunnelPhotoScale.medium.rawValue
    @AppStorage("OneDay.rewindSortOrder") private var rewindSortOrderRaw = RewindSortOrder.reverse.rawValue
    @AppStorage(MediaCategorySelection.rewindStorageKey)
    private var rewindMediaSelection = MediaCategorySelection.all

    private var tunnelPhotoScale: TunnelPhotoScale { TunnelPhotoScale(rawValue: tunnelPhotoScaleRaw) ?? .medium }
    private var rewindSortOrder: RewindSortOrder { RewindSortOrder(rawValue: rewindSortOrderRaw) ?? .reverse }
    private var effectiveRewindMediaSelection: MediaCategorySelection {
        rewindMediaSelection.includingPrimary
    }

    private let tunnelMinPhotos = 3
    private let tunnelPhotosPerDay = 3...5
    private let rewindRandomCount = 39
    private let tunnelInitialLayerCount = 6
    private let tunnelLayerBatchSize = 4
    private let tunnelLoadConcurrency = 6
    private let tunnelPreviewSize = CGSize(width: 190, height: 238)
    private let tunnelHighQualitySize = CGSize(width: 270, height: 338)

    var body: some View {
        ZStack {
            switch phase {
            case .home:
                TunnelRewindView(
                    model: dayModel,
                    layers: tunnelLayers,
                    initialLoadProgress: tunnelOpeningProgress,
                    isOpening: tunnelOpeningActive,
                    dateNamespace: dateNamespace,
                    mediaSelection: Binding(
                        get: { effectiveRewindMediaSelection },
                        set: { rewindMediaSelection = $0.includingPrimary }
                    ),
                    startDate: tunnelStartDate,
                    onInteractionLockChanged: { locked in
                        tunnelInteractionLocked = locked
                        if locked {
                            tunnelUpdateID = UUID()
                            tunnelUpdateTask?.cancel()
                        } else if tunnelNeedsUpdate {
                            scheduleTunnelUpdate()
                        }
                    },
                    onLand: { req in
                        let target = req.date
                        Task {
                            if let model = await makeDayModel(for: target) {
                                if let layer = tunnelLayers.first(where: {
                                    Calendar.current.isDate($0.date, inSameDayAs: target)
                                }) {
                                    model.setTunnelCoverPhoto(from: layer)
                                }
                                self.dayModel = model
                                tunnelStartDate = model.date
                                dayFromTunnel = true
                                // Continuous buzz that tracks the cover's
                                // slide-up speed (easeInOut over 0.5s).
                                playEntranceHaptic(duration: 0.5)
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    phase = .day
                                } completion: {
                                    // Cover has finished rising to the top.
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                        }
                    }
                )
                .id(rewindHomeID)
                .transition(.opacity)

            case .day:
                if let dayModel {
                    DayPagedStackView(
                        model: dayModel,
                        dateNamespace: dateNamespace,
                        dateIsSource: false,
                        coverDateMatched: !dayFromTunnel,
                        onClose: { closeDay() },
                        historyEntries: historyEntries,
                        historyLoading: historyLoading,
                        onSelectHistoryDay: { date in navigate(to: date) },
                        prevDate: previousDate(for: dayModel.date),
                        nextDate: nextDate(for: dayModel.date),
                        onPrevDay: { if let date = previousDate(for: dayModel.date) { navigate(to: date) } },
                        onNextDay: { if let date = nextDate(for: dayModel.date) { navigate(to: date) } },
                        navLoading: navLoading
                    )
                    .id(dayModel.instanceID)
                    .transition(dayFromTunnel
                        ? .asymmetric(insertion: .move(edge: .bottom), removal: .opacity)
                        : .opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: phase)
        .alert("无法访问相册", isPresented: $showPermissionAlert) {
            Button("好") {}
        } message: {
            Text("请在「设置 > 隐私 > 照片」中允许 OneDay 访问你的照片。")
        }
        .alert("还没有可回顾的日子", isPresented: $showEmptyAlert) {
            Button("好") {}
        } message: {
            Text("相册里暂时没有可回顾的过去某天。")
        }
        .task {
            DayAppearancePreferences.migrateLegacySettings()
            rewindMediaSelection = MediaCategorySelection.stored(
                forKey: MediaCategorySelection.rewindStorageKey)
            prepareHaptics()
        }
        .task {
            let task = Task { await prepareRewind() }
            tunnelPreparationTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onChange(of: dayModel?.date) { _, newDate in
            guard let newDate else {
                historyTask?.cancel()
                historyEntries = []
                historyLoading = false
                historyReferenceDay = nil
                historyPreparationID = UUID()
                dayNavigationRequestID = UUID()
                navigationDaysLoading = false
                sourceRefreshRequestID = UUID()
                return
            }
            guard phase == .day else { return }
            refreshDayContext(for: newDate)
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .day, let date = dayModel?.date {
                refreshDayContext(for: date)
            } else if newPhase != .day {
                historyTask?.cancel()
                historyPreparationID = UUID()
                historyReferenceDay = nil
                dayNavigationRequestID = UUID()
                navigationDaysLoading = false
                sourceRefreshRequestID = UUID()
            }
            if newPhase == .home, tunnelNeedsUpdate {
                tunnelInteractionLocked = false
                scheduleTunnelUpdate()
            }
        }
        .onChange(of: rewindSortOrderRaw) { _, _ in
            guard phase == .home else { return }
            if !tunnelOpeningActive, !tunnelLayers.isEmpty {
                tunnelLayers = applyRewindSort(to: tunnelLayers)
                let byDate = Dictionary(uniqueKeysWithValues: tunnelSelections.map { ($0.date, $0) })
                tunnelSelections = tunnelLayers.compactMap { byDate[$0.date] }
            }
            scheduleTunnelUpdate()
        }
        .onChange(of: rewindMediaSelection) { _, _ in
            guard phase == .home else { return }
            scheduleTunnelUpdate()
        }
        .onChange(of: tunnelOpeningActive) { _, opening in
            if !opening, tunnelNeedsUpdate { scheduleTunnelUpdate() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageClassificationChanged).receive(on: RunLoop.main)) { notification in
            let changed = notification.userInfo?["changed"] as? Bool ?? false
            let finished = notification.userInfo?["finished"] as? Bool ?? false
            if changed {
                if phase == .day { dayModel?.refreshMediaClassifications() }
                if effectiveRewindMediaSelection.respondsToClassificationChanges {
                    tunnelClassificationRevision += 1
                    tunnelNeedsUpdate = true
                }
            }
            guard finished else { return }
            if tunnelNeedsUpdate, phase == .home {
                scheduleTunnelUpdate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoLibraryContentChanged)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)) { _ in
            refreshLibraryContext()
        }
    }

    private func scheduleTunnelUpdate() {
        tunnelNeedsUpdate = true
        guard phase == .home, !tunnelOpeningActive,
              !tunnelInteractionLocked, rewindCandidateIndex != nil else { return }
        // Stop stale initial sharpening, not the view's opening/camera state.
        tunnelPreparationTask?.cancel()
        rewindPreparationID = UUID()
        tunnelUpdateTask?.cancel()
        let requestID = UUID()
        tunnelUpdateID = requestID
        tunnelUpdateTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await updateTunnelInPlace(requestID: requestID)
        }
    }

    private func updateTunnelInPlace(requestID: UUID) async {
        guard let index = rewindCandidateIndex else { return }
        let selection = effectiveRewindMediaSelection
        let order = rewindSortOrder
        let classificationRevision = tunnelClassificationRevision
        await OtherImageClassificationService.shared.indexIfNeeded(matching: selection)
        let plan = await index.plan(
            matching: selection, preserving: tunnelSelections,
            minimumCount: tunnelMinPhotos, maximumDays: rewindRandomCount + 1,
            newestFirst: order == .reverse
        )
        guard tunnelUpdateIsCurrent(requestID, selection: selection, order: order) else { return }
        let groups = index.groups(for: plan)
        // Remove excluded pictures immediately, but keep every surviving object.
        let existingByDate = Dictionary(uniqueKeysWithValues: tunnelLayers.map { ($0.date, $0) })
        let retained = plan.map { day in
            let photos = Dictionary(uniqueKeysWithValues:
                (existingByDate[day.date]?.photos ?? []).map { ($0.assetIdentifier, $0) })
            return TunnelLayer(date: day.date, photos: day.assetIdentifiers.compactMap { photos[$0] })
        }
        tunnelSelections = plan
        tunnelLayers = retained

        let retainedIDs = Set(retained.flatMap(\.photos).map(\.assetIdentifier))
        let missing = groups.compactMap { entry -> (date: Date, assets: [PHAsset])? in
            let assets = entry.assets.filter { !retainedIDs.contains($0.localIdentifier) }
            return assets.isEmpty ? nil : (entry.date, assets)
        }
        let batches = stride(from: 0, to: missing.count, by: tunnelLayerBatchSize).map {
            Array(missing[$0..<min($0 + tunnelLayerBatchSize, missing.count)])
        }
        let photoScale = tunnelPhotoScale
        for batch in batches {
            let images = await ImageLoader.shared.thumbnails(
                assets: batch.flatMap(\.assets), size: tunnelPreviewSize, quality: .fast,
                priority: .userInitiated, contentMode: .aspectFit, maxConcurrent: tunnelLoadConcurrency
            )
            guard tunnelUpdateIsCurrent(requestID, selection: selection, order: order) else { return }
            mergeTunnelPhotoChanges(Self.makeTunnelLayers(
                batch, images: images, photoScale: photoScale, preserving: tunnelLayers
            ))
        }
        guard tunnelUpdateIsCurrent(requestID, selection: selection, order: order) else { return }
        // A classification batch may have arrived while these thumbnails loaded.
        // Keep the pending flag until a plan includes that newer batch.
        tunnelNeedsUpdate = classificationRevision != tunnelClassificationRevision
        let currentPhotos = Dictionary(uniqueKeysWithValues:
            tunnelLayers.flatMap(\.photos).map { ($0.assetIdentifier, $0) })
        let unsharpened = groups.compactMap { entry -> (date: Date, assets: [PHAsset])? in
            let assets = entry.assets.filter { currentPhotos[$0.localIdentifier]?.isHighQuality != true }
            return assets.isEmpty ? nil : (entry.date, assets)
        }
        let sharpBatches = stride(from: 0, to: unsharpened.count, by: tunnelLayerBatchSize).map {
            Array(unsharpened[$0..<min($0 + tunnelLayerBatchSize, unsharpened.count)])
        }
        // Do not re-request retained sharp images. Interrupted initial previews
        // still get their pending quality upgrade without restarting the opening.
        for batch in sharpBatches {
            let images = await ImageLoader.shared.thumbnails(
                assets: batch.flatMap(\.assets), size: tunnelHighQualitySize, quality: .highQuality,
                priority: .background, contentMode: .aspectFit, maxConcurrent: tunnelLoadConcurrency
            )
            guard tunnelUpdateIsCurrent(requestID, selection: selection, order: order) else { return }
            mergeTunnelPhotoChanges(Self.makeTunnelLayers(
                batch, images: images, photoScale: photoScale, preserving: tunnelLayers, highQuality: true
            ))
        }
    }

    private func tunnelUpdateIsCurrent(
        _ requestID: UUID, selection: MediaCategorySelection, order: RewindSortOrder
    ) -> Bool {
        tunnelUpdateID == requestID && !Task.isCancelled && phase == .home
            && !tunnelInteractionLocked
            && effectiveRewindMediaSelection == selection && rewindSortOrder == order
    }

    private func mergeTunnelPhotoChanges(_ changed: [TunnelLayer]) {
        let changedByDate = Dictionary(uniqueKeysWithValues: changed.map { ($0.date, $0) })
        let currentByDate = Dictionary(uniqueKeysWithValues: tunnelLayers.map { ($0.date, $0) })
        tunnelLayers = tunnelSelections.map { day in
            var photos = Dictionary(uniqueKeysWithValues:
                (currentByDate[day.date]?.photos ?? []).map { ($0.assetIdentifier, $0) })
            for photo in changedByDate[day.date]?.photos ?? [] {
                photos[photo.assetIdentifier] = photo
            }
            return TunnelLayer(date: day.date, photos: day.assetIdentifiers.compactMap { photos[$0] })
        }
    }

    // MARK: Haptics

    private func prepareHaptics() {
        guard hapticEngine == nil,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.resetHandler = { [engine] in try? engine.start() }
            engine.stoppedHandler = { _ in }
            try engine.start()
            hapticEngine = engine
        } catch {
            hapticEngine = nil
        }
    }

    /// Play a faint continuous buzz whose intensity follows the cover's slide-up
    /// speed: an easeInOut motion is slowest at the ends and fastest in the
    /// middle, so the intensity rises to a peak at the midpoint then eases off.
    private func playEntranceHaptic(duration: Double) {
        guard let engine = hapticEngine else { return }
        do {
            try engine.start()
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
                ],
                relativeTime: 0,
                duration: duration
            )
            let curve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0, value: 0.05),
                    .init(relativeTime: duration * 0.25, value: 0.20),
                    .init(relativeTime: duration * 0.5, value: 0.30),
                    .init(relativeTime: duration * 0.75, value: 0.25),
                    .init(relativeTime: duration, value: 0.10)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameterCurves: [curve])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    private func prepareRewind() async {
        guard tunnelLayers.isEmpty else { return }
        let preparationID = UUID()
        rewindPreparationID = preparationID
        tunnelOpeningProgress = 0
        tunnelOpeningActive = true
        defer {
            if rewindPreparationID == preparationID {
                tunnelOpeningActive = false
            }
        }

        let status = await PhotoLibraryService.shared.authorize()
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        guard status == .authorized || status == .limited else {
            showPermissionAlert = true
            return
        }
        // Warm the shared-album cache off the critical path so the landing
        // day's `items(on:)` does not stall the cover entrance.
        Task.detached(priority: .utility) { await SharedAlbumCache.shared.warm() }
        let index = await PhotoLibraryService.shared.rewindCandidates(photosPerDay: tunnelPhotosPerDay)
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        rewindCandidateIndex = index
        let selection = effectiveRewindMediaSelection
        await OtherImageClassificationService.shared.indexIfNeeded(matching: selection)
        let plan = await index.plan(
            matching: selection, preserving: [], minimumCount: tunnelMinPhotos,
            maximumDays: rewindRandomCount + 1, newestFirst: rewindSortOrder == .reverse
        )
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        tunnelSelections = plan
        let sortedGroup = index.groups(for: plan)
        guard !sortedGroup.isEmpty else {
            // A valid library can have no matches under the tunnel toggles.
            // Keep its candidate index and let the tunnel show its empty state.
            if index.days.isEmpty { showEmptyAlert = true }
            return
        }

        let photoScale = tunnelPhotoScale
        let initialGroup = Array(sortedGroup.prefix(tunnelInitialLayerCount))
        let initialAssets = initialGroup.flatMap(\.assets)

        let newest = sortedGroup[0].date
        guard let items = await landingItems(on: newest) else {
            showEmptyAlert = true
            return
        }
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }

        // Publish the tunnel structure before requesting images. Its chrome is
        // already on screen, and each completed opening layer can now appear
        // immediately instead of waiting behind a separate loading page.
        dayModel = DayViewModel(date: newest, items: items)
        tunnelLayers = sortedGroup.map { TunnelLayer(date: $0.date, photos: []) }
        tunnelStartDate = nil

        // Load all initial layers concurrently (instead of anchor-first) so
        // the first photos appear as early as possible.
        var completedOpeningLayers = 0
        await withTaskGroup(of: (Int, [UIImage?]).self) { group in
            for (index, entry) in initialGroup.enumerated() {
                group.addTask(priority: .userInitiated) {
                    let images = await ImageLoader.shared.thumbnails(
                        assets: entry.assets,
                        size: tunnelPreviewSize,
                        quality: .fast,
                        priority: .userInitiated,
                        contentMode: .aspectFit,
                        maxConcurrent: 1
                    )
                    return (index, images)
                }
            }

            for await (index, images) in group {
                guard rewindPreparationID == preparationID,
                      !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                let loaded = Self.makeTunnelLayers(
                    [initialGroup[index]],
                    images: images,
                    photoScale: photoScale,
                    preserving: tunnelLayers
                )
                mergeTunnelLayers(loaded)
                completedOpeningLayers += 1
                tunnelOpeningProgress = Double(completedOpeningLayers)
                    / Double(max(initialGroup.count, 1))
            }
        }

        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        guard let anchor = tunnelLayers.first, !anchor.photos.isEmpty else {
            tunnelLayers = []
            dayModel = nil
            showEmptyAlert = true
            return
        }
        tunnelOpeningProgress = 1
        tunnelOpeningActive = false

        // Let the six opening layers finish their smooth approach before later
        // batches begin appearing behind them.
        try? await Task.sleep(nanoseconds: 650_000_000)
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }

        let remainingGroup = Array(sortedGroup.dropFirst(initialGroup.count))
        let remainingBatches = stride(
            from: 0,
            to: remainingGroup.count,
            by: tunnelLayerBatchSize
        ).map { start in
            Array(remainingGroup[start..<min(start + tunnelLayerBatchSize, remainingGroup.count)])
        }

        // Populate every remaining day quickly so the camera never has to wait
        // for far-away high-quality images before the tunnel can be explored.
        for batch in remainingBatches {
            guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
            let images = await ImageLoader.shared.thumbnails(
                assets: batch.flatMap(\.assets),
                size: tunnelPreviewSize,
                quality: .fast,
                priority: .normal,
                contentMode: .aspectFit,
                maxConcurrent: tunnelLoadConcurrency
            )
            guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
            let loaded = Self.makeTunnelLayers(
                batch,
                images: images,
                photoScale: photoScale,
                preserving: tunnelLayers
            )
            mergeTunnelLayers(loaded)
        }

        // Once every day has a preview, sharpen the visible opening layers first.
        let initialHighQualityImages = await ImageLoader.shared.thumbnails(
            assets: initialAssets,
            size: tunnelHighQualitySize,
            quality: .highQuality,
            priority: .userInitiated,
            contentMode: .aspectFit,
            maxConcurrent: tunnelLoadConcurrency
        )
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        let sharpenedInitialLayers = Self.makeTunnelLayers(
            initialGroup,
            images: initialHighQualityImages,
            photoScale: photoScale,
            preserving: tunnelLayers,
            highQuality: true
        )
        mergeTunnelLayers(sharpenedInitialLayers)

        // Upgrade previews in small, low-priority batches. The shared loader
        // reuses cached results and cancellation propagates when preparation stops.
        for batch in remainingBatches {
            guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
            let images = await ImageLoader.shared.thumbnails(
                assets: batch.flatMap(\.assets),
                size: tunnelHighQualitySize,
                quality: .highQuality,
                priority: .background,
                contentMode: .aspectFit,
                maxConcurrent: tunnelLoadConcurrency
            )
            guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
            let loaded = Self.makeTunnelLayers(
                batch,
                images: images,
                photoScale: photoScale,
                preserving: tunnelLayers,
                highQuality: true
            )
            mergeTunnelLayers(loaded)
        }
    }

    private static func makeTunnelLayers(
        _ group: [(date: Date, assets: [PHAsset])],
        images: [UIImage?],
        photoScale: TunnelPhotoScale,
        preserving existingLayers: [TunnelLayer],
        highQuality: Bool = false
    ) -> [TunnelLayer] {
        let existingByDate = Dictionary(
            uniqueKeysWithValues: existingLayers.map { ($0.date, $0) }
        )
        var imageIndex = 0
        return group.map { entry in
            let existingPhotos = Dictionary(
                uniqueKeysWithValues: (existingByDate[entry.date]?.photos ?? []).map {
                    ($0.assetIdentifier, $0)
                }
            )
            let count = entry.assets.count
            let dayPhase = Double.random(in: 0..<(2 * .pi))
            var photos: [TunnelPhoto] = []

            for (assetIndex, asset) in entry.assets.enumerated() {
                let image = images.indices.contains(imageIndex) ? images[imageIndex] : nil
                imageIndex += 1

                if let image {
                    if let existing = existingPhotos[asset.localIdentifier] {
                        photos.append(TunnelPhoto(
                            image: image,
                            assetIdentifier: asset.localIdentifier,
                            angle: existing.angle,
                            radius: existing.radius,
                            zJitter: existing.zJitter,
                            size: existing.size,
                            id: existing.id,
                            isHighQuality: highQuality
                        ))
                    } else {
                        let aspect = asset.pixelHeight > 0
                            ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                            : image.size.width / max(image.size.height, 1)
                        let longSide = photoScale.base + CGFloat.random(in: -12...12)
                        let size: CGSize = aspect >= 1
                            ? CGSize(width: longSide, height: longSide / aspect)
                            : CGSize(width: longSide * aspect, height: longSide)
                        let baseAngle = (2 * .pi / Double(max(count, 1))) * Double(assetIndex)
                        photos.append(TunnelPhoto(
                            image: image,
                            assetIdentifier: asset.localIdentifier,
                            angle: dayPhase + baseAngle + Double.random(in: -0.4...0.4),
                            radius: Double.random(in: 0.45...1.0),
                            zJitter: Double.random(in: -0.34...0.34),
                            size: size,
                            isHighQuality: highQuality
                        ))
                    }
                } else if let existing = existingPhotos[asset.localIdentifier] {
                    photos.append(existing)
                }
            }
            return TunnelLayer(date: entry.date, photos: photos)
        }
    }

    private func mergeTunnelLayers(_ loaded: [TunnelLayer]) {
        let loadedByDate = Dictionary(uniqueKeysWithValues: loaded.map { ($0.date, $0) })
        tunnelLayers = tunnelLayers.map { loadedByDate[$0.date] ?? $0 }
    }

    private func landingItems(on date: Date) async -> [PhotoItem]? {
        let items = await PhotoLibraryService.shared.items(on: date)
        return items.isEmpty ? nil : items
    }

    private func refreshDayContext(for day: Date) {
        prepareTodayInHistoryIfNeeded(for: day)
        loadNavigationDaysIfNeeded()
    }

    private func loadNavigationDaysIfNeeded() {
        guard !navigationDaysLoaded, !navigationDaysLoading else { return }
        navigationDaysLoading = true
        let requestID = UUID()
        dayNavigationRequestID = requestID
        Task {
            let days = await PhotoLibraryService.shared.eligibleDays()
            guard dayNavigationRequestID == requestID, phase == .day else { return }
            navigationDays = days
            navigationDaysLoaded = true
            navigationDaysLoading = false
        }
    }

    private func prepareTodayInHistoryIfNeeded(for day: Date, force: Bool = false) {
        let referenceDate = Calendar.current.startOfDay(for: day)
        guard force || historyReferenceDay != referenceDate else { return }
        historyTask?.cancel()
        let sameReference = historyReferenceDay == referenceDate
        historyReferenceDay = referenceDate
        if !sameReference {
            historyEntries = historyCache[referenceDate] ?? []
        }
        historyLoading = historyCache[referenceDate] == nil && historyEntries.isEmpty

        let requestID = UUID()
        historyPreparationID = requestID
        let previous = historyEntries
        historyTask = Task {
            let snapshot = await PhotoLibraryService.shared.todayInHistory(
                referenceDate: referenceDate, preserving: previous)
            guard !Task.isCancelled, phase == .day, historyPreparationID == requestID,
                  historyReferenceDay == referenceDate else { return }
            if historyEntries != snapshot.entries { historyEntries = snapshot.entries }
            historyLoading = false
            cacheHistory(referenceDate)
            await PhotoLibraryService.shared.resolveHistoryPlaces(in: snapshot) { entry in
                guard !Task.isCancelled, phase == .day, historyPreparationID == requestID,
                      historyReferenceDay == referenceDate,
                      let index = historyEntries.firstIndex(where: { $0.date == entry.date }),
                      historyEntries[index] != entry else { return }
                historyEntries[index] = entry
                cacheHistory(referenceDate)
            }
        }
    }

    private func cacheHistory(_ referenceDate: Date) {
        historyCache[referenceDate] = historyEntries
        if historyCache.count > 12, let key = historyCache.keys.first(where: { $0 != referenceDate }) {
            historyCache.removeValue(forKey: key)
        }
    }

    private func refreshLibraryContext() {
        navigationDaysLoaded = false
        navigationDaysLoading = false
        dayNavigationRequestID = UUID()
        guard phase == .day, let model = dayModel else { return }
        prepareTodayInHistoryIfNeeded(for: model.date, force: true)
        loadNavigationDaysIfNeeded()
        let requestID = UUID()
        sourceRefreshRequestID = requestID
        let sourceRevision = model.sourceRevision
        Task {
            let items = await PhotoLibraryService.shared.items(on: model.date)
            guard sourceRefreshRequestID == requestID, phase == .day,
                  dayModel?.instanceID == model.instanceID,
                  model.sourceRevision == sourceRevision else { return }
            model.replaceSourceItems(items)
        }
    }

    private func applyRewindSort(to layers: [TunnelLayer]) -> [TunnelLayer] {
        guard !layers.isEmpty else { return layers }
        let calendar = Calendar.current
        let anchor = layers.max { $0.date < $1.date }!
        let rest = layers.filter { !calendar.isDate($0.date, inSameDayAs: anchor.date) }
        switch rewindSortOrder {
        case .reverse:
            return [anchor] + rest.sorted { $0.date > $1.date }
        case .random:
            return [anchor] + rest.shuffled()
        }
    }

    private func previousDate(for date: Date) -> Date? {
        DayMediaScope.previousDay(before: date, in: navigationDays)
    }

    private func nextDate(for date: Date) -> Date? {
        DayMediaScope.nextDay(after: date, in: navigationDays)
    }

    private func navigate(to date: Date) {
        guard !navLoading else { return }
        let origin = dayModel?.instanceID
        navLoading = true
        Task {
            defer { navLoading = false }
            let model = await makeDayModel(for: date)
            guard phase == .day, dayModel?.instanceID == origin else { return }
            if let model {
                dayFromTunnel = false
                withAnimation(.easeInOut(duration: 0.35)) {
                    dayModel = model
                    phase = .day
                }
            } else {
                navigationDaysLoaded = false
                loadNavigationDaysIfNeeded()
            }
        }
    }

    private func makeDayModel(for day: Date) async -> DayViewModel? {
        let items = await PhotoLibraryService.shared.items(on: day)
        guard !items.isEmpty else { return nil }
        return DayViewModel(date: day, items: items)
    }

    private func closeDay() {
        tunnelStartDate = dayModel?.date
        rewindHomeID = UUID()
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .home
        }
    }
}
