import SwiftUI
import Photos
import UIKit
import QuartzCore

/// The day the tunnel landed on, handed back to the host synchronously.
/// Arguments passed through a stored `async` closure get zeroed to the reference
/// date (Swift async reabstraction-thunk miscompile), so landing is reported via a
/// plain synchronous callback and the host does the async load itself.
final class TunnelDayRequest {
    let date: Date
    init(_ date: Date) { self.date = date }
}

/// One depth plane in the tunnel: a single day with a few photos scattered on the
/// tube wall around it.
struct TunnelLayer: Identifiable {
    let id = UUID()
    let date: Date
    let photos: [TunnelPhoto]
}

/// A single photo floating on the tube wall of its day.
struct TunnelPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
    let angle: Double     // radians around the tube axis
    let radius: Double    // 0...1 fraction of the reference radius
    let zJitter: Double   // per-photo depth offset (drives staggered speed)
    let size: CGSize      // display size at scale = 1 (aspect-correct)
}

/// Cinematic depth-tunnel rewind. Days sit along the Z axis; photos are scattered
/// on a tube wall so the camera flies down the hollow center and they stream out
/// past the screen edges. Depth-of-field keeps the focus plane crisp while near and
/// far photos blur; constant camera velocity yields natural acceleration + stagger.
struct TunnelRewindView: View {
    let model: DayViewModel
    let layers: [TunnelLayer]
    let control: TunnelControl
    let dateNamespace: Namespace.ID
    var startDate: Date? = nil
    var onLand: (TunnelDayRequest) -> Void

    // MARK: Live-editable settings persisted via @AppStorage
    @AppStorage("OneDay.rewindMode") private var rewindModeRaw = RewindMode.flash.rawValue
    @AppStorage("OneDay.tunnelControl") private var tunnelControlRaw = TunnelControl.auto.rawValue
    @AppStorage("OneDay.rewindSortOrder") private var rewindSortOrderRaw = RewindSortOrder.reverse.rawValue
    @AppStorage("OneDay.tunnelBackground") private var backgroundRaw = TunnelBackground.dark.rawValue
    @AppStorage("OneDay.tunnelTextPosition") private var textPositionRaw = TunnelTextPosition.center.rawValue
    @AppStorage("OneDay.tunnelSpread") private var spreadRaw = TunnelSpread.medium.rawValue
    @AppStorage("OneDay.tunnelPhotoScale") private var photoScaleRaw = TunnelPhotoScale.medium.rawValue
    @AppStorage("OneDay.tunnelOverflow") private var overflowRaw = TunnelOverflow.medium.rawValue

    private var background: TunnelBackground { TunnelBackground(rawValue: backgroundRaw) ?? .dark }
    private var textPosition: TunnelTextPosition { TunnelTextPosition(rawValue: textPositionRaw) ?? .center }
    private var spread: TunnelSpread { TunnelSpread(rawValue: spreadRaw) ?? .medium }
    private var overflow: TunnelOverflow { TunnelOverflow(rawValue: overflowRaw) ?? .medium }
    private var rewindSortOrder: RewindSortOrder { RewindSortOrder(rawValue: rewindSortOrderRaw) ?? .reverse }

    // MARK: Perspective / look constants
    private let focal: Double = 1.0          // depth where a layer is full size (scale = 1)
    private var nearCull: Double { overflow.nearCull } // closer than this = culled
    private let farVisible: Double = 7.0     // farther than this = invisible
    private let focusBand: Double = 0.10     // depth half-width kept perfectly sharp
    private let maxFarBlur: Double = 5.0
    private let maxNearBlur: Double = 9.0
    private let border: CGFloat = 2.5
    private let autoDuration: Double = 6.0   // seconds for the full flythrough
    private let rampTime: Double = 0.6       // ease-in of camera velocity

    // MARK: Motion state
    private enum Mode { case awaitingStart, autoPlay, manualIdle, manualDrag, momentum, settling, done }

    @State private var progress: Double
    @State private var clock: Double = 0
    @State private var mode: Mode
    @State private var velocity: Double = 0
    @State private var settleTarget: Double = 0
    @State private var autoElapsed: Double = 0
    @State private var dragStartProgress: Double = 0
    @State private var lastFocus: Int = -1
    @State private var pendingLandDate: Date?

    @State private var displayDate: Date
    @State private var topLabel = "回到"
    @State private var isFinishing = false
    @State private var hasStarted = false
    @State private var settingsShown = false

    init(model: DayViewModel, layers: [TunnelLayer], control: TunnelControl,
         dateNamespace: Namespace.ID,
         startDate: Date? = nil,
         onLand: @escaping (TunnelDayRequest) -> Void) {
        self.model = model
        self.layers = layers
        self.control = control
        self.dateNamespace = dateNamespace
        self.startDate = startDate
        self.onLand = onLand
        let startIndex = startDate.flatMap { d in
            layers.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: d) }
        } ?? 0
        let start = Double(startIndex) - 1.0   // = snapProgress(for: startIndex), 1.0 = focal
        _progress = State(initialValue: start)
        _mode = State(initialValue: control == .auto ? .awaitingStart : .manualIdle)
        let initialDate = layers.indices.contains(startIndex) ? layers[startIndex].date : model.date
        _displayDate = State(initialValue: initialDate)
    }

    private var count: Int { layers.count }
    private var progressStart: Double { -focal }
    private var landProgress: Double { Double(max(count - 1, 0)) - focal }

    private func focusIndex(_ p: Double) -> Int {
        guard count > 0 else { return 0 }
        return min(max(Int((p + focal).rounded()), 0), count - 1)
    }
    private func snapProgress(for index: Int) -> Double { Double(index) - focal }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background.color.ignoresSafeArea()
                Canvas { context, size in
                    draw(&context, size: size)
                }
                .ignoresSafeArea()
                if background.isDark { vignette }
                if textPosition == .bottom {
                    VStack {
                        Spacer()
                        dateOverlay
                            .padding(.bottom, 96)
                    }
                } else {
                    dateOverlay
                }
                hint
                if control == .auto, mode == .awaitingStart {
                    startButton
                }
                VStack {
                    HStack {
                        modeMenu
                        Spacer()
                        settingsMenu
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(control == .manual ? dragGesture : nil)
            .onTapGesture { if control != .manual && mode == .autoPlay { handleTap() } }
            .environment(\.colorScheme, background.scheme)
        }
        .opacity(isFinishing ? 0 : 1)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            SoundEffects.warmUp()
            await runLoop()
        }
    }

    // MARK: Canvas rendering

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard count > 0 else { return }
        // Smaller reference radius keeps photos framed inside the screen.
        let ref = Double(min(size.width, size.height)) * 0.5
        let baseCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        // Gentle handheld position drift (no photo rotation).
        let drift = CGSize(width: sin(clock * 0.55) * 12, height: cos(clock * 0.43) * 9)

        struct Proj {
            let image: UIImage
            let rect: CGRect
            let blur: Double
            let opacity: Double
            let depth: Double
        }

        var projected: [Proj] = []
        for (i, layer) in layers.enumerated() {
            for photo in layer.photos {
                let z = Double(i) + photo.zJitter
                let depth = z - progress
                guard depth > nearCull, depth < farVisible else { continue }
                let scale = focal / depth
                // Fade a photo out before it grows large enough to spill off screen;
                // the threshold is the user's "冲屏程度" setting.
                let opacity = fog(depth) * smoothstep(overflow.fadeEnd, overflow.fadeStart, scale)
                guard opacity > 0.01 else { continue }
                let screenR = photo.radius * spread.factor * ref * scale
                let pos = CGPoint(x: baseCenter.x + drift.width + CGFloat(cos(photo.angle) * screenR),
                                  y: baseCenter.y + drift.height + CGFloat(sin(photo.angle) * screenR))
                let w = photo.size.width * CGFloat(scale)
                let h = photo.size.height * CGFloat(scale)
                let rect = CGRect(x: pos.x - w / 2, y: pos.y - h / 2, width: w, height: h)
                projected.append(Proj(
                    image: photo.image,
                    rect: rect,
                    blur: dofBlur(depth),
                    opacity: opacity,
                    depth: depth))
            }
        }
        // Painter's order: farthest first.
        projected.sort { $0.depth > $1.depth }

        let frameColor: Color = background.isDark ? Color(white: 0.93) : .white
        for p in projected {
            context.drawLayer { layer in
                layer.opacity = p.opacity
                if p.blur > 0.3 { layer.addFilter(.blur(radius: p.blur)) }
                let frameRect = p.rect.insetBy(dx: -border, dy: -border)
                layer.fill(Path(roundedRect: frameRect, cornerRadius: 2),
                           with: .color(frameColor))
                layer.draw(layer.resolve(Image(uiImage: p.image)), in: p.rect)
            }
        }
    }

    /// Depth-of-field blur: sharp within the focus band, ramping to soft far-blur
    /// and heavier near-blur.
    private func dofBlur(_ depth: Double) -> Double {
        let d = depth - focal
        if abs(d) <= focusBand { return 0 }
        if d > 0 {
            let t = min((d - focusBand) / (farVisible - focal - focusBand), 1)
            return pow(t, 1.3) * maxFarBlur
        } else {
            let t = min((-d - focusBand) / (focal - nearCull - focusBand), 1)
            return pow(t, 1.3) * maxNearBlur
        }
    }

    /// Fade in from the far fog, fade out as a layer rushes past the camera.
    private func fog(_ depth: Double) -> Double {
        let farFade = smoothstep(farVisible, farVisible - 1.4, depth)
        let nearFade = smoothstep(nearCull, nearCull + 0.4, depth)
        return farFade * nearFade
    }

    // MARK: Overlays

    private var modeMenu: some View {
        Menu {
            Picker("穿梭模式", selection: Binding(
                get: { RewindMode(rawValue: rewindModeRaw) ?? .flash },
                set: { rewindModeRaw = $0.rawValue }
            )) {
                ForEach(RewindMode.allCases) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var startButton: some View {
        VStack {
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                autoElapsed = 0
                mode = .autoPlay
            } label: {
                Text("时光穿梭")
                    .font(Theme.serif(20, weight: .semibold))
                    .tracking(6)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Theme.ink)
                    )
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }

    private var settingsMenu: some View {
        Button {
            settingsShown = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .popover(isPresented: $settingsShown, arrowEdge: .top) {
            settingsPanel
                .presentationCompactAdaptation(.popover)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingGroup("控制方式") {
                Picker("", selection: Binding(
                    get: { TunnelControl(rawValue: tunnelControlRaw) ?? .auto },
                    set: { tunnelControlRaw = $0.rawValue }
                )) {
                    ForEach(TunnelControl.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            settingGroup("排序") {
                Picker("", selection: Binding(
                    get: { rewindSortOrder },
                    set: { rewindSortOrderRaw = $0.rawValue }
                )) {
                    ForEach(RewindSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
            }
            Divider()
            settingGroup("背景色") {
                Picker("", selection: Binding(
                    get: { background }, set: { backgroundRaw = $0.rawValue }
                )) {
                    ForEach(TunnelBackground.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            settingGroup("文字位置") {
                Picker("", selection: Binding(
                    get: { textPosition }, set: { textPositionRaw = $0.rawValue }
                )) {
                    ForEach(TunnelTextPosition.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Divider()
            Text("画面调节")
                .font(.headline)

            settingGroup("扩散范围") {
                Picker("", selection: Binding(
                    get: { spread }, set: { spreadRaw = $0.rawValue }
                )) {
                    ForEach(TunnelSpread.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            settingGroup("照片大小") {
                Picker("", selection: Binding(
                    get: { TunnelPhotoScale(rawValue: photoScaleRaw) ?? .medium },
                    set: { photoScaleRaw = $0.rawValue }
                )) {
                    ForEach(TunnelPhotoScale.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            settingGroup("冲屏程度") {
                Picker("", selection: Binding(
                    get: { overflow }, set: { overflowRaw = $0.rawValue }
                )) {
                    ForEach(TunnelOverflow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(20)
        .frame(width: 330)
    }

    @ViewBuilder
    private func settingGroup<Content: View>(_ title: String,
                                             @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, .black.opacity(0.55)],
            center: .center, startRadius: 60, endRadius: 520
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var dateOverlay: some View {
        VStack(spacing: 30) {
            Text(topLabel)
                .font(Theme.serif(16))
                .tracking(6)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.15), value: topLabel)
            BigDateView(date: displayDate)
                .matchedGeometryEffect(id: "flowDate", in: dateNamespace, isSource: true)
                .shadow(color: background.color.opacity(0.9), radius: 14)
        }
        .allowsHitTesting(false)
    }

    private var hint: some View {
        VStack {
            Spacer()
            if mode != .settling && mode != .done && mode != .awaitingStart {
                Text(control == .manual ? "上下滑动穿梭 · 点击进入这一天" : "点击屏幕，停在某一天")
                    .font(Theme.serif(13))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 50)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Controls

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Keep small movements as a potential tap; only begin dragging
                // once the finger clearly moves.
                if mode != .manualDrag, abs(value.translation.height) < 8 { return }
                if mode != .manualDrag {
                    mode = .manualDrag
                    dragStartProgress = progress
                }
                let delta = -value.translation.height / 150.0
                progress = clampTravel(dragStartProgress + Double(delta))
            }
            .onEnded { value in
                if mode == .manualDrag {
                    velocity = Double(-value.predictedEndTranslation.height / 150.0) * 2.2
                    mode = .momentum
                } else {
                    // Treated as a tap: enter the day currently in focus.
                    handleTap()
                }
            }
    }

    private func handleTap() {
        guard mode != .settling, mode != .done else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let idx = focusIndex(progress)
        pendingLandDate = layers[idx].date
        settleTarget = snapProgress(for: idx)
        mode = .settling
    }

    // MARK: Frame loop

    private func runLoop() async {
        var last = CACurrentMediaTime()
        while mode != .done && !Task.isCancelled {
            // While the settings popover is open, keep redrawing (drift + live
            // preview of spread/overflow) but freeze travel so it can't auto-finish.
            try? await Task.sleep(nanoseconds: settingsShown ? 33_000_000 : 8_000_000)
            let now = CACurrentMediaTime()
            let dt = min(now - last, 1.0 / 30.0)
            last = now
            clock += dt
            guard !settingsShown else { continue }
            step(dt)
            updateFocus()
        }
    }

    private func step(_ dt: Double) {
        switch mode {
        case .autoPlay:
            autoElapsed += dt
            let travel = landProgress - progressStart
            let vMax = travel / max(autoDuration - rampTime * 0.5, 0.1)
            let v = vMax * smoothstep(0, rampTime, autoElapsed)
            progress += v * dt
            if progress >= landProgress {
                progress = landProgress
                pendingLandDate = layers.last?.date
                beginFinishFromSettle()
            }
        case .momentum:
            progress = clampTravel(progress + velocity * dt)
            velocity *= exp(-dt / 0.45)
            if abs(velocity) < 0.6 || progress <= progressStart || progress >= landProgress {
                settleTarget = snapProgress(for: focusIndex(progress))
                mode = .settling
            }
        case .settling:
            progress += (settleTarget - progress) * min(1, dt * 11)
            if abs(settleTarget - progress) < 0.004 {
                progress = settleTarget
                if pendingLandDate != nil {
                    beginFinishFromSettle()
                } else {
                    mode = .manualIdle
                }
            }
        case .awaitingStart, .manualDrag, .manualIdle, .done:
            break
        }
    }

    private func updateFocus() {
        let idx = focusIndex(progress)
        guard idx != lastFocus, idx >= 0, idx < count else { return }
        lastFocus = idx
        displayDate = layers[idx].date
        if mode != .settling && mode != .done {
            SoundEffects.tick()
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55)
        }
    }

    private func beginFinishFromSettle() {
        guard mode != .done else { return }
        mode = .done
        Task { await finish(on: pendingLandDate ?? layers[focusIndex(progress)].date) }
    }

    // MARK: Landing

    private func finish(on date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        displayDate = day
        topLabel = DateText.relativeCaption(day) ?? "那一天"
        SoundEffects.settle()
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        onLand(TunnelDayRequest(day))
    }

    // MARK: Math helpers

    private func clampTravel(_ p: Double) -> Double {
        min(max(p, progressStart), landProgress)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
