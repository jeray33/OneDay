import SwiftUI
import UIKit
import CoreLocation

struct FlashFrame: Identifiable {
    let id = UUID()
    let date: Date
    let image: UIImage
    let location: CLLocation?
}

/// Hosts the full "time travel" flow: photos flash past with their dates,
/// then the date settles and rises to the masthead as the magazine reveals.
/// Tapping anywhere during the flash stops on that date and enters that day.
struct DayFlowView: View {
    let model: DayViewModel
    let flashFrames: [FlashFrame]
    let dateNamespace: Namespace.ID
    var loadDay: (Date) async -> DayViewModel?
    var onFinish: (DayViewModel) -> Void
    var onClose: () -> Void
    var onReroll: () -> Void

    @State private var displayDate: Date
    @State private var flashImage: UIImage?
    @State private var topLabel = "回到"
    @State private var places: [UUID: String] = [:]
    @State private var currentFrame: FlashFrame?
    @State private var stoppedFrame: FlashFrame?
    @State private var tappedDate: Date?
    @State private var shouldStop = false
    @State private var isFinishing = false
    @State private var hasStarted = false

    init(model: DayViewModel, flashFrames: [FlashFrame], dateNamespace: Namespace.ID,
         loadDay: @escaping (Date) async -> DayViewModel?,
         onFinish: @escaping (DayViewModel) -> Void,
         onClose: @escaping () -> Void, onReroll: @escaping () -> Void) {
        self.model = model
        self.flashFrames = flashFrames
        self.dateNamespace = dateNamespace
        self.loadDay = loadDay
        self.onFinish = onFinish
        self.onClose = onClose
        self.onReroll = onReroll
        _displayDate = State(initialValue: flashFrames.first?.date ?? model.date)
        _flashImage = State(initialValue: flashFrames.first?.image)
    }

    var body: some View {
        counting
            .opacity(isFinishing ? 0 : 1)
        .task(id: flashFrames.count) {
            guard !hasStarted, !flashFrames.isEmpty else { return }
            hasStarted = true
            await run()
        }
        .task { await resolvePlaces() }
    }

    // MARK: Counting overlay

    private var counting: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 34) {
                flashCard
                Text(topLabel)
                    .font(Theme.serif(16))
                    .tracking(6)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.15), value: topLabel)
                BigDateView(date: displayDate)
                    .matchedGeometryEffect(id: "flowDate", in: dateNamespace, isSource: true)
            }
            VStack {
                Spacer()
                if tappedDate == nil {
                    Text(flashFrames.isEmpty ? "正在回到那一天" : "点击屏幕，停在某一天")
                        .font(Theme.serif(13))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 50)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
    }

    private var flashCard: some View {
        ZStack {
            if let image = flashImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 250)
                    .clipped()
                    .padding(8)
                    .background(Theme.frame)
                    .shadow(color: .black.opacity(0.18), radius: 9, x: 0, y: 5)
                    .id(image)
                    .transition(.opacity)
            }
        }
        .frame(width: 216, height: 266)
        .animation(.easeOut(duration: 0.09), value: flashImage)
    }

    private func handleTap() {
        guard !shouldStop else { return }
        // Freeze on the exact frame the user is looking at, so the photo and the
        // date below it always belong to the same moment.
        stoppedFrame = currentFrame
        tappedDate = currentFrame?.date ?? displayDate
        shouldStop = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Flash run

    private func run() async {
        SoundEffects.warmUp()
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()

        if flashFrames.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        } else {
            let frames = flashFrames.shuffled()
            let count = frames.count
            for (i, frame) in frames.enumerated() {
                if shouldStop { break }
                currentFrame = frame
                withAnimation(.easeOut(duration: 0.09)) { flashImage = frame.image }
                displayDate = frame.date
                topLabel = places[frame.id] ?? "回到"
                SoundEffects.tick()

                let t = count > 1 ? Double(i) / Double(count - 1) : 1
                generator.impactOccurred(intensity: CGFloat(0.3 + 0.6 * t))
                let delay = lerp(0.012, 0.17, easeOut(t))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        var landingModel = model
        let tapped = tappedDate != nil
        if let tappedDate {
            let day = Calendar.current.startOfDay(for: tappedDate)
            if let picked = await loadDay(day) {
                landingModel = picked
            }
            await pinFlashImage(to: landingModel)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                displayDate = landingModel.date
            }
        } else {
            await pinFlashImage(to: landingModel)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                displayDate = landingModel.date
            }
        }

        topLabel = DateText.relativeCaption(landingModel.date) ?? "那一天"
        SoundEffects.settle()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        try? await Task.sleep(nanoseconds: tapped ? 1_300_000_000 : 360_000_000)

        onFinish(landingModel)
    }

    private func pinFlashImage(to model: DayViewModel) async {
        guard let item = model.allItems.first else { return }
        if let image = await ImageLoader.shared.thumbnail(asset: item.asset,
                                                          size: CGSize(width: 240, height: 300)) {
            withAnimation(.easeOut(duration: 0.12)) {
                flashImage = image
            }
        }
    }

    private func resolvePlaces() async {
        for frame in flashFrames {
            guard let location = frame.location else { continue }
            if let name = await LocationResolver.shared.name(for: location) {
                places[frame.id] = name
            }
        }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
