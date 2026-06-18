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
    @State private var preparing = false
    @State private var navLoading = false
    @State private var showPermissionAlert = false
    @State private var showEmptyAlert = false
    @Namespace private var dateNamespace

    var body: some View {
        ZStack {
            switch phase {
            case .home:
                HomeView(onPickDay: pickDay)
                    .transition(.opacity)

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
                        onClose: { goHome() },
                        onReroll: { pickDay() }
                    )
                    .id(id)
                    .transition(.opacity)
                }

            case .day:
                if let dayModel {
                    DayMagazineView(
                        model: dayModel,
                        dateNamespace: dateNamespace,
                        dateIsSource: false,
                        contentRevealed: true,
                        onClose: { goHome() },
                        onReroll: { pickDay() },
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

            dayModel = DayViewModel(date: target, items: items)
            eligibleDays = days
            flashFrames = []
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

    private func goHome() {
        withAnimation(.easeInOut(duration: 0.4)) {
            phase = .home
            dayModel = nil
            eligibleDays = []
            flashFrames = []
            navLoading = false
        }
    }
}
