import SwiftUI
import Photos

struct RootView: View {
    private enum Phase: Equatable {
        case home
        case rewinding(UUID)
        case day
    }

    @State private var phase: Phase = .home
    @State private var dayModel: DayViewModel?
    @State private var eligibleDays: [Date] = []
    @State private var flashFrames: [FlashFrame] = []
    @State private var tunnelLayers: [TunnelLayer] = []
    @State private var tunnelStartDate: Date?
    @State private var rewindHomeID = UUID()
    @State private var rewindPreparationID = UUID()
    @State private var tunnelOpeningProgress = 0.0
    @State private var tunnelOpeningActive = true
    @State private var preparing = false
    @State private var navLoading = false
    @State private var historyEntries: [TodayInHistoryEntry] = []
    @State private var historyLoading = false
    @State private var historyReferenceDay: Date?
    @State private var showPermissionAlert = false
    @State private var showEmptyAlert = false
    @Namespace private var dateNamespace
    @AppStorage("OneDay.rewindMode") private var rewindModeRaw = RewindMode.flash.rawValue
    @AppStorage("OneDay.tunnelPhotoScale") private var tunnelPhotoScaleRaw = TunnelPhotoScale.medium.rawValue
    @AppStorage("OneDay.rewindSortOrder") private var rewindSortOrderRaw = RewindSortOrder.reverse.rawValue

    private var rewindMode: RewindMode { RewindMode(rawValue: rewindModeRaw) ?? .flash }
    private var tunnelPhotoScale: TunnelPhotoScale { TunnelPhotoScale(rawValue: tunnelPhotoScaleRaw) ?? .medium }
    private var rewindSortOrder: RewindSortOrder { RewindSortOrder(rawValue: rewindSortOrderRaw) ?? .reverse }

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
                if rewindMode == .rewind {
                    TunnelRewindView(
                        model: dayModel,
                        layers: tunnelLayers,
                        initialLoadProgress: tunnelOpeningProgress,
                        isOpening: tunnelOpeningActive,
                        dateNamespace: dateNamespace,
                        startDate: tunnelStartDate,
                        onLand: { req in
                            let target = req.date
                            Task {
                                if let model = await makeDayModel(for: target) {
                                    if let layer = tunnelLayers.first(where: {
                                        Calendar.current.isDate($0.date, inSameDayAs: target)
                                    }) {
                                        model.setTunnelCoverPhotos(from: layer, drift: req.drift)
                                    }
                                    self.dayModel = model
                                    tunnelStartDate = model.date
                                    withAnimation(.easeInOut(duration: 0.5)) {
                                        phase = .day
                                    }
                                }
                            }
                        }
                    )
                    .id(rewindHomeID)
                    .transition(.opacity)
                } else {
                    HomeView(onPickDay: pickDay)
                        .transition(.opacity)
                }

            case .rewinding(let id):
                if let dayModel {
                    DayFlowView(
                        model: dayModel,
                        flashFrames: flashFrames,
                        dateNamespace: dateNamespace,
                        loadDay: { day in await makeDayModel(for: day) },
                        onFinish: { model in
                            self.dayModel = model
                            withAnimation(.easeInOut(duration: 0.35)) {
                                phase = .day
                            }
                        },
                        onClose: { goHome() }
                    )
                    .id(id)
                    .transition(.opacity)
                }

            case .day:
                if let dayModel {
                    DayPagedStackView(
                        model: dayModel,
                        dateNamespace: dateNamespace,
                        dateIsSource: false,
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
                    .transition(.opacity)
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
        .task(id: rewindModeRaw) {
            if rewindMode == .rewind { await prepareRewind() }
        }
        .onChange(of: dayModel?.date) { _, newDate in
            guard let newDate else {
                historyEntries = []
                historyLoading = false
                historyReferenceDay = nil
                return
            }
            guard phase == .day else { return }
            prepareTodayInHistoryIfNeeded(for: newDate)
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .day, let date = dayModel?.date {
                prepareTodayInHistoryIfNeeded(for: date)
            }
        }
        .onChange(of: rewindModeRaw) { _, newValue in
            let mode = RewindMode(rawValue: newValue) ?? .flash
            if mode != .rewind, phase == .home {
                rewindPreparationID = UUID()
                tunnelOpeningProgress = 0
                tunnelOpeningActive = true
                tunnelLayers = []
                dayModel = nil
                tunnelStartDate = nil
            } else if mode == .rewind, phase == .home {
                tunnelOpeningProgress = 0
                tunnelOpeningActive = true
            }
        }
        .onChange(of: rewindSortOrderRaw) { _, _ in
            if rewindMode == .rewind, phase == .home,
               !tunnelOpeningActive, !tunnelLayers.isEmpty {
                tunnelLayers = applyRewindSort(to: tunnelLayers)
                tunnelStartDate = nil
                rewindHomeID = UUID()
            }
        }
    }

    private func prepareRewind() async {
        guard rewindMode == .rewind else { return }
        guard tunnelLayers.isEmpty else { return }
        let preparationID = UUID()
        rewindPreparationID = preparationID
        tunnelOpeningProgress = 0
        tunnelOpeningActive = true
        defer {
            if rewindPreparationID == preparationID {
                if tunnelOpeningProgress < 1 {
                    tunnelOpeningActive = false
                }
            }
        }

        let status = await PhotoLibraryService.shared.authorize()
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        guard status == .authorized || status == .limited else {
            showPermissionAlert = true
            return
        }
        let group = await PhotoLibraryService.shared.rewindGroup(
            randomCount: rewindRandomCount,
            minPhotos: tunnelMinPhotos,
            photosPerDay: tunnelPhotosPerDay
        )
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        let sortedGroup = sortRewindGroup(group, by: rewindSortOrder)
        guard !sortedGroup.isEmpty else {
            showEmptyAlert = true
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
        flashFrames = []
        tunnelStartDate = nil

        // Load the anchor first so there is always a visible layer entering from
        // the distance; the five random layers then finish concurrently.
        let anchorImages = await ImageLoader.shared.thumbnails(
            assets: initialGroup[0].assets,
            size: tunnelPreviewSize,
            quality: .fast,
            priority: .userInitiated,
            contentMode: .aspectFit,
            maxConcurrent: tunnelLoadConcurrency
        )
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }
        let loadedAnchor = Self.makeTunnelLayers(
            [initialGroup[0]],
            images: anchorImages,
            photoScale: photoScale,
            preserving: tunnelLayers
        )
        mergeTunnelLayers(loadedAnchor)
        var completedOpeningLayers = 1
        tunnelOpeningProgress = 1 / Double(max(initialGroup.count, 1))

        await withTaskGroup(of: (Int, [UIImage?]).self) { group in
            for index in initialGroup.indices.dropFirst() {
                let entry = initialGroup[index]
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
            preserving: tunnelLayers
        )
        mergeTunnelLayers(sharpenedInitialLayers)

        eligibleDays = await PhotoLibraryService.shared.eligibleDays()
        guard rewindPreparationID == preparationID, !Task.isCancelled else { return }

        // Upgrade previews in small, low-priority batches. The shared loader
        // reuses cached results and cancellation propagates when the mode changes.
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
                preserving: tunnelLayers
            )
            mergeTunnelLayers(loaded)
        }
    }

    private static func makeTunnelLayers(
        _ group: [(date: Date, assets: [PHAsset])],
        images: [UIImage?],
        photoScale: TunnelPhotoScale,
        preserving existingLayers: [TunnelLayer]
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
                            size: existing.size
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
                            size: size
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

    private func pickDay() {
        Task {
            preparing = true
            defer { preparing = false }

            let status = await PhotoLibraryService.shared.authorize()
            guard status == .authorized || status == .limited else {
                showPermissionAlert = true
                return
            }
            let days = await PhotoLibraryService.shared.eligibleDays()
            guard let target = days.randomElement() else {
                showEmptyAlert = true
                return
            }
            let items = await PhotoLibraryService.shared.items(on: target)
            guard !items.isEmpty else {
                showEmptyAlert = true
                return
            }

            eligibleDays = days

            dayModel = DayViewModel(date: target, items: items)
            tunnelLayers = []
            flashFrames = []
            tunnelStartDate = nil
            withAnimation(.easeInOut(duration: 0.4)) {
                phase = .rewinding(UUID())
            }

            let assets = await PhotoLibraryService.shared.randomAssets(count: 50)
            let frames = await loadFrames(assets)
            if frames.isEmpty, let first = items.first {
                flashFrames = await loadFrames([first.asset])
            } else {
                flashFrames = frames
            }
        }
    }

    private func landingItems(on date: Date) async -> [PhotoItem]? {
        let items = await PhotoLibraryService.shared.items(on: date)
        return items.isEmpty ? nil : items
    }

    private func prepareTodayInHistoryIfNeeded(for day: Date) {
        let referenceDate = Calendar.current.startOfDay(for: day)
        guard historyReferenceDay != referenceDate else { return }
        historyReferenceDay = referenceDate
        historyEntries = []
        historyLoading = true

        Task {
            let entries = await PhotoLibraryService.shared.todayInHistory(referenceDate: referenceDate)
            guard historyReferenceDay == referenceDate else { return }
            historyEntries = entries
            historyLoading = false
        }
    }

    private func sortRewindGroup(
        _ group: [(date: Date, assets: [PHAsset])],
        by order: RewindSortOrder
    ) -> [(date: Date, assets: [PHAsset])] {
        guard !group.isEmpty else { return group }
        let calendar = Calendar.current
        let anchor = group.max { $0.date < $1.date }!
        let rest = group.filter { !calendar.isDate($0.date, inSameDayAs: anchor.date) }
        switch order {
        case .reverse:
            return [anchor] + rest.sorted { $0.date > $1.date }
        case .random:
            return [anchor] + rest.shuffled()
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
        let current = Calendar.current.startOfDay(for: date)
        return eligibleDays.first { $0 < current }
    }

    private func nextDate(for date: Date) -> Date? {
        let current = Calendar.current.startOfDay(for: date)
        return eligibleDays.last { $0 > current }
    }

    private func navigate(to date: Date) {
        guard !navLoading else { return }
        navLoading = true
        Task {
            defer { navLoading = false }
            if let model = await makeDayModel(for: date) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    dayModel = model
                    phase = .day
                }
            } else {
                eligibleDays = await PhotoLibraryService.shared.eligibleDays()
            }
        }
    }

    private func makeDayModel(for day: Date) async -> DayViewModel? {
        let items = await PhotoLibraryService.shared.items(on: day)
        guard !items.isEmpty else { return nil }
        return DayViewModel(date: day, items: items)
    }

    private func loadFrames(_ assets: [PHAsset]) async -> [FlashFrame] {
        await withTaskGroup(of: FlashFrame?.self) { group in
            for asset in assets {
                group.addTask {
                    guard let image = await ImageLoader.shared.thumbnail(
                        asset: asset, size: CGSize(width: 240, height: 300)) else { return nil }
                    return FlashFrame(date: asset.creationDate ?? Date(),
                                      image: image,
                                      location: asset.location)
                }
            }
            var result: [FlashFrame] = []
            for await frame in group {
                if let frame { result.append(frame) }
            }
            return result
        }
    }

    private func closeDay() {
        if rewindMode == .rewind, !tunnelLayers.isEmpty {
            tunnelStartDate = dayModel?.date
            rewindHomeID = UUID()
            withAnimation(.easeInOut(duration: 0.4)) {
                phase = .home
            }
        } else {
            goHome()
        }
    }

    private func goHome() {
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .home
            dayModel = nil
            eligibleDays = []
            flashFrames = []
            tunnelLayers = []
            tunnelStartDate = nil
            navLoading = false
        }
    }
}
