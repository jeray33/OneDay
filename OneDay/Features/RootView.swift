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
    @State private var rewindPreparing = false
    @State private var preparing = false
    @State private var navLoading = false
    @State private var historyEntries: [TodayInHistoryEntry] = []
    @State private var historyLoading = false
    @State private var historyReferenceDay: Date?
    @State private var showPermissionAlert = false
    @State private var showEmptyAlert = false
    @Namespace private var dateNamespace
    @AppStorage("OneDay.rewindMode") private var rewindModeRaw = RewindMode.flash.rawValue
    @AppStorage("OneDay.tunnelControl") private var tunnelControlRaw = TunnelControl.auto.rawValue
    @AppStorage("OneDay.tunnelPhotoScale") private var tunnelPhotoScaleRaw = TunnelPhotoScale.medium.rawValue
    @AppStorage("OneDay.rewindSortOrder") private var rewindSortOrderRaw = RewindSortOrder.reverse.rawValue

    private var rewindMode: RewindMode { RewindMode(rawValue: rewindModeRaw) ?? .flash }
    private var tunnelControl: TunnelControl { TunnelControl(rawValue: tunnelControlRaw) ?? .auto }
    private var tunnelPhotoScale: TunnelPhotoScale { TunnelPhotoScale(rawValue: tunnelPhotoScaleRaw) ?? .medium }
    private var rewindSortOrder: RewindSortOrder { RewindSortOrder(rawValue: rewindSortOrderRaw) ?? .reverse }

    private let tunnelMinPhotos = 3
    private let tunnelPhotosPerDay = 3...5
    private let rewindRandomCount = 39

    var body: some View {
        ZStack {
            switch phase {
            case .home:
                if rewindMode == .rewind {
                    if !tunnelLayers.isEmpty, let dayModel {
                        TunnelRewindView(
                            model: dayModel,
                            layers: tunnelLayers,
                            control: tunnelControl,
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
                    } else if rewindPreparing {
                        preparingOverlay
                    } else {
                        HomeView(onPickDay: pickDay)
                            .transition(.opacity)
                    }
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
        .task {
            if rewindMode == .rewind { await prepareRewind() }
        }
        .onChange(of: dayModel?.date) { _, newDate in
            guard let newDate else {
                historyEntries = []
                historyLoading = false
                historyReferenceDay = nil
                return
            }
            prepareTodayInHistoryIfNeeded(for: newDate)
        }
        .onChange(of: rewindModeRaw) { _, newValue in
            let mode = RewindMode(rawValue: newValue) ?? .flash
            if mode == .rewind {
                Task { await prepareRewind() }
            } else if phase == .home {
                tunnelLayers = []
                dayModel = nil
                tunnelStartDate = nil
            }
        }
        .onChange(of: tunnelControlRaw) { _, _ in
            if rewindMode == .rewind, phase == .home, !tunnelLayers.isEmpty {
                rewindHomeID = UUID()
            }
        }
        .onChange(of: rewindSortOrderRaw) { _, _ in
            if rewindMode == .rewind, phase == .home, !tunnelLayers.isEmpty {
                tunnelLayers = applyRewindSort(to: tunnelLayers)
                tunnelStartDate = nil
                rewindHomeID = UUID()
            }
        }
    }

    private func prepareRewind() async {
        guard rewindMode == .rewind else { return }
        guard tunnelLayers.isEmpty, !rewindPreparing else { return }
        rewindPreparing = true
        defer { rewindPreparing = false }

        let status = await PhotoLibraryService.shared.authorize()
        guard status == .authorized || status == .limited else {
            showPermissionAlert = true
            return
        }
        let group = await PhotoLibraryService.shared.rewindGroup(
            randomCount: rewindRandomCount,
            minPhotos: tunnelMinPhotos,
            photosPerDay: tunnelPhotosPerDay
        )
        let sortedGroup = sortRewindGroup(group, by: rewindSortOrder)
        let layers = await loadTunnelLayers(sortedGroup, photoScale: tunnelPhotoScale)
        guard let newest = layers.first?.date,
              let items = await landingItems(on: newest),
              !layers.isEmpty else {
            showEmptyAlert = true
            return
        }
        eligibleDays = await PhotoLibraryService.shared.eligibleDays()
        dayModel = DayViewModel(date: newest, items: items)
        tunnelLayers = layers
        flashFrames = []
        tunnelStartDate = nil
        rewindHomeID = UUID()
    }

    private var preparingOverlay: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            ProgressView().tint(Theme.ink)
        }
        .transition(.opacity)
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

    private func loadTunnelLayers(_ group: [(date: Date, assets: [PHAsset])],
                                  photoScale: TunnelPhotoScale) async -> [TunnelLayer] {
        await withTaskGroup(of: (Int, TunnelLayer)?.self) { taskGroup in
            for (index, entry) in group.enumerated() {
                taskGroup.addTask {
                    var photos: [TunnelPhoto] = []
                    let count = entry.assets.count
                    // Spread photos around a "tube wall": evenly-spaced base angles with
                    // jitter, plus a random day phase so consecutive days don't line up.
                    let dayPhase = Double.random(in: 0..<(2 * .pi))
                    for (j, asset) in entry.assets.enumerated() {
                        guard let image = await ImageLoader.shared.thumbnail(
                            asset: asset, size: CGSize(width: 270, height: 338),
                            highQuality: true) else { continue }

                        let aspect = image.size.width / max(image.size.height, 1)
                        let longSide = photoScale.base + CGFloat.random(in: -12...12)
                        let size: CGSize = aspect >= 1
                            ? CGSize(width: longSide, height: longSide / aspect)
                            : CGSize(width: longSide * aspect, height: longSide)

                        let baseAngle = (2 * .pi / Double(max(count, 1))) * Double(j)
                        let angle = dayPhase + baseAngle + Double.random(in: -0.4...0.4)
                        photos.append(TunnelPhoto(
                            image: image,
                            assetIdentifier: asset.localIdentifier,
                            angle: angle,
                            radius: Double.random(in: 0.45...1.0),
                            zJitter: Double.random(in: -0.34...0.34),
                            size: size))
                    }
                    guard !photos.isEmpty else { return nil }
                    return (index, TunnelLayer(date: entry.date, photos: photos))
                }
            }
            var collected: [(Int, TunnelLayer)] = []
            for await result in taskGroup {
                if let result { collected.append(result) }
            }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
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
