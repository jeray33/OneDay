import SwiftUI
import Photos
import UIKit
import QuartzCore
import CoreMotion

/// The day the tunnel landed on, handed back to the host synchronously.
/// Arguments passed through a stored `async` closure get zeroed to the reference
/// date (Swift async reabstraction-thunk miscompile), so landing is reported via a
/// plain synchronous callback and the host does the async load itself.
final class TunnelDayRequest {
    let date: Date
    init(_ date: Date) {
        self.date = date
    }
}

/// One depth plane in the tunnel: a single day with a few photos scattered on the
/// tube wall around it.
struct TunnelLayer: Identifiable {
    let date: Date
    let photos: [TunnelPhoto]

    var id: Date { date }
}

/// A single photo floating on the tube wall of its day.
struct TunnelPhoto: Identifiable {
    let id: UUID
    let image: UIImage
    let assetIdentifier: String
    let angle: Double     // radians around the tube axis
    let radius: Double    // 0...1 fraction of the reference radius
    let zJitter: Double   // per-photo depth offset (drives staggered speed)
    let size: CGSize      // display size at scale = 1 (aspect-correct)
    let isHighQuality: Bool

    init(image: UIImage, assetIdentifier: String, angle: Double, radius: Double,
         zJitter: Double, size: CGSize, id: UUID = UUID(), isHighQuality: Bool = false) {
        self.id = id
        self.image = image
        self.assetIdentifier = assetIdentifier
        self.angle = angle
        self.radius = radius
        self.zJitter = zJitter
        self.size = size
        self.isHighQuality = isHighQuality
    }
}

enum TunnelPhotoBlur: String, CaseIterable, Identifiable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case max = "max"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "关"
        case .low: return "1"
        case .medium: return "2"
        case .high: return "3"
        case .max: return "4"
        }
    }
    var amount: Double {
        switch self {
        case .off: return 0
        case .low: return 3
        case .medium: return 7
        case .high: return 12
        case .max: return 18
        }
    }
}

/// Cinematic depth-tunnel rewind. Days sit along the Z axis; photos are scattered
/// on a tube wall so the camera flies down the hollow center and they stream out
/// past the screen edges. Depth-of-field keeps the focus plane crisp while near and
/// far photos blur; constant camera velocity yields natural acceleration + stagger.
struct TunnelRewindView: View {
    let model: DayViewModel?
    let layers: [TunnelLayer]
    let initialLoadProgress: Double
    let isOpening: Bool
    let dateNamespace: Namespace.ID
    @Binding var mediaSelection: MediaCategorySelection
    var startDate: Date? = nil
    var onInteractionLockChanged: (Bool) -> Void
    var onLand: (TunnelDayRequest) -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // MARK: Live-editable settings persisted via @AppStorage
    @AppStorage("OneDay.rewindMode") private var rewindModeRaw = RewindMode.flash.rawValue
    @AppStorage("OneDay.rewindSortOrder") private var rewindSortOrderRaw = RewindSortOrder.reverse.rawValue
    @AppStorage("OneDay.tunnelTapMode") private var tapModeRaw = TunnelTapMode.anywhere.rawValue
    @AppStorage("OneDay.tunnelLandingMotion") private var landingMotionRaw = TunnelLandingMotion.none.rawValue
    @AppStorage("OneDay.tunnelBackground") private var backgroundRaw = TunnelBackground.dark.rawValue
    @AppStorage("OneDay.tunnelTextPosition") private var textPositionRaw = TunnelTextPosition.center.rawValue
    @AppStorage("OneDay.tunnelSpread") private var spreadRaw = TunnelSpread.medium.rawValue
    @AppStorage("OneDay.tunnelPhotoScale") private var photoScaleRaw = TunnelPhotoScale.medium.rawValue
    @AppStorage("OneDay.tunnelDepthSpacing") private var depthSpacingRaw = TunnelDepthSpacing.standard.rawValue
    @AppStorage("OneDay.tunnelPhotoDepthSpacing") private var photoDepthSpacingRaw = TunnelPhotoDepthSpacing.standard.rawValue
    @AppStorage("OneDay.tunnelSpeedContrast") private var speedContrastRaw = TunnelSpeedContrast.natural.rawValue
    @AppStorage("OneDay.tunnelOverflow") private var overflowRaw = TunnelOverflow.medium.rawValue
    @AppStorage("OneDay.tunnelPhotoBlur") private var photoBlurRaw = TunnelPhotoBlur.off.rawValue

    private var tapMode: TunnelTapMode { TunnelTapMode(rawValue: tapModeRaw) ?? .anywhere }
    private var landingMotion: TunnelLandingMotion { TunnelLandingMotion(rawValue: landingMotionRaw) ?? .none }
    private var background: TunnelBackground { TunnelBackground(rawValue: backgroundRaw) ?? .dark }
    private var textPosition: TunnelTextPosition { TunnelTextPosition(rawValue: textPositionRaw) ?? .center }
    private var spread: TunnelSpread { TunnelSpread(rawValue: spreadRaw) ?? .medium }
    private var depthSpacing: TunnelDepthSpacing { TunnelDepthSpacing(rawValue: depthSpacingRaw) ?? .standard }
    private var photoDepthSpacing: TunnelPhotoDepthSpacing {
        TunnelPhotoDepthSpacing(rawValue: photoDepthSpacingRaw) ?? .standard
    }
    private var speedContrast: TunnelSpeedContrast { TunnelSpeedContrast(rawValue: speedContrastRaw) ?? .natural }
    private var overflow: TunnelOverflow { TunnelOverflow(rawValue: overflowRaw) ?? .medium }
    private var photoBlur: TunnelPhotoBlur { TunnelPhotoBlur(rawValue: photoBlurRaw) ?? .off }
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
    private let openingDuration: Double = 2.0 // seconds for the staggered opening reveal
    private let openingOverlap: Double = 8.0  // 1 = sequential, 2 = 50% overlap, 3 = 67% overlap
    private let dateRevealDuration: Double = 0.4 // seconds for the date title to fade in
    private let dateRevealDelay: Double = 0.3   // seconds to wait before date starts (after tunnel begins)

    // MARK: Motion state
    private enum Mode: Equatable {
        case autoPlay, manualIdle, manualDrag, momentum, settling, photoZooming, rushingOut, done

        var locksContent: Bool {
            switch self {
            case .settling, .photoZooming, .rushingOut, .done: return true
            default: return false
            }
        }
    }

    @State private var progress: Double
    @State private var clock: Double = 0
    @State private var mode: Mode
    @State private var velocity: Double = 0
    @State private var settleTarget: Double = 0
    @State private var autoElapsed: Double = 0
    @State private var dragStartProgress: Double = 0
    @State private var lastFocus: Int = -1
    @State private var pendingLandDate: Date?
    @State private var layerDates: [Date]
    @State private var openingTargetProgress: Double
    @State private var openingVisualProgress: Double
    @State private var openingActive: Bool

    @State private var displayDate: Date
    @State private var isFinishing = false
    @State private var hasStarted = false
    @State private var settingsShown = false
    @State private var motionManager = CMMotionManager()
    @State private var referenceRoll: Double?
    @State private var referencePitch: Double?
    @State private var tiltOffset: CGSize = .zero
    @State private var dateRevealProgress: Double = 0
    @State private var hintVisible: Bool = false
    @State private var openingEndedAt: Double = -1
    @State private var tappedPhotoID: UUID?
    @State private var tappedPhotoScale: Double = 1.0
    @State private var hasStartedLanding = false
    @State private var photoTapTraveling = false
    @State private var settledOpeningLayers = 0
    @State private var openingHapticsInitialized = false
    @State private var openingImpact = UIImpactFeedbackGenerator(style: .soft)


    init(model: DayViewModel?, layers: [TunnelLayer],
         initialLoadProgress: Double = 1,
         isOpening: Bool = false,
         dateNamespace: Namespace.ID,
         mediaSelection: Binding<MediaCategorySelection>,
         startDate: Date? = nil,
         onInteractionLockChanged: @escaping (Bool) -> Void = { _ in },
         onLand: @escaping (TunnelDayRequest) -> Void) {
        self.model = model
        self.layers = layers
        self.initialLoadProgress = initialLoadProgress
        self.isOpening = isOpening
        self.dateNamespace = dateNamespace
        _mediaSelection = mediaSelection
        self.startDate = startDate
        self.onInteractionLockChanged = onInteractionLockChanged
        self.onLand = onLand
        let startIndex = startDate.flatMap { d in
            layers.firstIndex { Calendar.current.isDate($0.date, inSameDayAs: d) }
        } ?? 0
        let storedSpacing = UserDefaults.standard.string(forKey: "OneDay.tunnelDepthSpacing")
            .flatMap(TunnelDepthSpacing.init(rawValue:)) ?? .standard
        let start = Double(startIndex) * storedSpacing.factor - 1.0
        _progress = State(initialValue: start)
        _mode = State(initialValue: .manualIdle)
        _layerDates = State(initialValue: layers.map(\.date))
        let openingProgress = isOpening ? max(initialLoadProgress, 0.02) : 1
        _openingTargetProgress = State(initialValue: openingProgress)
        _openingVisualProgress = State(initialValue: openingProgress)
        _openingActive = State(initialValue: isOpening)
        _dateRevealProgress = State(initialValue: isOpening ? 0 : 1)
        let initialDate = layers.indices.contains(startIndex)
            ? layers[startIndex].date
            : model?.date ?? Date()
        _displayDate = State(initialValue: initialDate)
    }

    private var count: Int { layerDates.count }
    private var progressStart: Double { -focal }
    private var landProgress: Double { Double(max(count - 1, 0)) * depthSpacing.factor - focal }

    private func focusIndex(_ p: Double) -> Int {
        guard count > 0 else { return 0 }
        return min(max(Int(((p + focal) / depthSpacing.factor).rounded()), 0), count - 1)
    }
    private func snapProgress(for index: Int) -> Double {
        Double(index) * depthSpacing.factor - focal
    }

    private var tunnelContent: some View {
        GeometryReader { geo in
            ZStack {
                background.color.ignoresSafeArea()
                Canvas { context, size in
                    draw(&context, size: size)
                }
                .progressiveBlur(radius: 18, maxSampleCount: 18) { geometry, context in
                    context.fill(
                        Path(geometry.frame(in: .local)),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0.00),
                                .init(color: .clear, location: 0.23),
                                .init(color: .clear, location: 0.77),
                                .init(color: .white, location: 1.00)
                            ]),
                            startPoint: CGPoint(x: geometry.size.width / 2, y: 0),
                            endPoint: CGPoint(x: geometry.size.width / 2,
                                              y: geometry.size.height)
                        )
                    )
                }
                .ignoresSafeArea()
                if background.isDark { vignette }
                // Loading indicator before the first photos arrive
                if openingIsActive && openingTargetProgress < 0.05 {
                    TunnelLoader()
                        .transition(.opacity)
                }
                // Gesture surface: transparent layer below interactive controls
                // so button taps don't bleed into drag/tap gestures.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(!openingIsActive && (
                        mode == .manualIdle || mode == .manualDrag || mode == .momentum
                    ) ? dragGesture(in: geo.size) : nil)
                    .onTapGesture { if mode == .autoPlay { handleTap() } }
                tunnelDateOverlay
                VStack {
                    Spacer()
                    if mode == .manualIdle && !openingIsActive {
                        playButton
                            .padding(.bottom, 40)
                            .disabled(layerDates.isEmpty)
                            .opacity(layerDates.isEmpty ? 0.45 : 1)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: mode)
                // Fixed bottom hint
                VStack {
                    //Spacer()
                    if hintVisible && mode != .settling && mode != .rushingOut && mode != .done {
                        Text(hintText)
                            .font(Theme.serif(12))
                            .foregroundStyle(.tertiary)
                            //.padding(.bottom, 24)
                            .padding(.top, 24)
                            .transition(.opacity)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
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
            .environment(\.colorScheme, background.scheme)
        }
    }

    private var observedTunnelContent: some View {
        tunnelContent
        .opacity(isFinishing ? 0 : 1)
        .onChange(of: layers.map(\.date), initial: true) { _, dates in
            updateLayerDates(dates)
        }
        .onChange(of: mode, initial: true) { _, mode in
            onInteractionLockChanged(mode.locksContent)
        }
        .onDisappear { onInteractionLockChanged(false) }
    }

    var body: some View {
        observedTunnelContent
        .onChange(of: initialLoadProgress, initial: true) { _, newProgress in
            openingTargetProgress = min(max(newProgress, 0), 1)
        }
        .onChange(of: isOpening, initial: true) { _, newValue in
            openingActive = newValue
            if !newValue { openingTargetProgress = 1 }
        }
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            SoundEffects.warmUp()
            startDeviceMotion()
            defer { stopDeviceMotion() }
            await runLoop()
        }
    }

    @ViewBuilder
    private var tunnelDateOverlay: some View {
        if layers.isEmpty && !isOpening {
            Text("当前筛选下没有可回顾的内容")
                .font(Theme.serif(15))
                .foregroundStyle(.secondary)
        } else if !layers.isEmpty {
            if textPosition == .bottom {
                VStack {
                    Spacer()
                    animatedDateOverlay.padding(.bottom, 96)
                }
            } else {
                animatedDateOverlay
            }
        }
    }

    private func updateLayerDates(_ dates: [Date]) {
        let oldProgress = progress
        progress = TunnelSelectionPlanner.remapProgress(
            progress, oldDates: layerDates, newDates: dates, spacing: depthSpacing.factor
        )
        dragStartProgress += progress - oldProgress
        settleTarget += progress - oldProgress
        layerDates = dates
        if dates.isEmpty {
            mode = .manualIdle
            velocity = 0
            pendingLandDate = nil
            lastFocus = -1
        } else {
            // Re-indexing is not camera travel: do not play a tick or reset motion.
            lastFocus = focusIndex(progress)
            displayDate = dates[lastFocus]
        }
    }

    // MARK: Canvas rendering

    /// Projected photo data used both for drawing and for hit testing.
    private struct ProjectedPhoto {
        let photoID: UUID
        let image: UIImage
        let rect: CGRect
        let blur: Double
        let opacity: Double
        let depth: Double
        let layerIndex: Int
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let projected = projectedPhotos(in: size).sorted { $0.depth > $1.depth }
        let frameColor: Color = background.isDark ? Color(white: 0.93) : .white
        let userBlur = photoBlur.amount
        for p in projected {
            let isTapped = p.photoID == tappedPhotoID
            let photoScale = isTapped ? CGFloat(tappedPhotoScale) : 1.0
            let rect = scaledRect(p.rect, by: photoScale)

            // Frame: drawn sharp (no blur) so edges stay crisp
            context.drawLayer { layer in
                layer.opacity = p.opacity
                let frameRect = rect.insetBy(dx: -border, dy: -border)
                layer.fill(Path(roundedRect: frameRect, cornerRadius: 2),
                           with: .color(frameColor))
            }
            // Image: drawn with depth-of-field + user blur, clipped to photo rect
            let totalBlur = p.blur + userBlur
            if totalBlur > 0.3 {
                var clipped = context
                clipped.clip(to: Path(roundedRect: rect, cornerRadius: 2))
                clipped.drawLayer { layer in
                    layer.opacity = p.opacity
                    layer.addFilter(.blur(radius: totalBlur))
                    layer.draw(layer.resolve(Image(uiImage: p.image)), in: rect)
                }
            } else {
                context.drawLayer { layer in
                    layer.opacity = p.opacity
                    layer.draw(layer.resolve(Image(uiImage: p.image)), in: rect)
                }
            }
        }
    }

    private func scaledRect(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        let scaledWidth = rect.width * scale
        let scaledHeight = rect.height * scale
        return CGRect(
            x: rect.midX - scaledWidth / 2,
            y: rect.midY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    /// Compute the screen-space projection of every visible tunnel photo.
    /// Used by both the Canvas renderer and the photo-tap hit tester.
    private func projectedPhotos(in size: CGSize) -> [ProjectedPhoto] {
        guard count > 0 else { return [] }
        // Smaller reference radius keeps photos framed inside the screen.
        let ref = Double(min(size.width, size.height)) * 0.5
        let baseCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        let drift = combinedDrift

        var projected: [ProjectedPhoto] = []
        let batchCount = Double(min(layers.count, 6))
        // Each layer starts `stagger` after the previous, but takes
        // `openingOverlap * stagger` to move — so consecutive layers
        // are in motion at the same time (cascading, not sequential).
        let stagger = 1.0 / batchCount
        let moveSpan = openingOverlap / batchCount
        let totalSpan = (batchCount - 1) * stagger + moveSpan
        for (i, layer) in layers.enumerated() {
            let localProgress: Double
            if i < 6 {
                let start = Double(i) * stagger / totalSpan
                let span = moveSpan / totalSpan
                localProgress = min(max((openingVisualProgress - start) / span, 0), 1)
            } else {
                localProgress = 1
            }
            let eased = 1 - pow(1 - localProgress, 3)
            let depthOffset = (1 - eased) * 5
            for photo in layer.photos {
                let z = Double(i) * depthSpacing.factor
                    + photo.zJitter * photoDepthSpacing.factor
                    + depthOffset
                let depth = z - progress
                guard depth > nearCull, depth < farVisible else { continue }
                // Keep the focus plane fixed at scale 1 while adjusting how
                // strongly perspective separates near and far movement.
                let projectionDepth = focal * pow(depth / focal, speedContrast.projectionExponent)
                let scale = focal / projectionDepth
                // Fade a photo out before it grows large enough to spill off screen;
                // the threshold is the user's "冲屏程度" setting.
                let opacity = fog(depth) * smoothstep(overflow.fadeEnd, overflow.fadeStart, scale)
                guard opacity > 0.01 else { continue }
                let screenR = photo.radius * spread.factor * ref * scale
                // The same depth curve drives ambient drift and device tilt:
                // near photos move faster, while distant photos move less.
                let driftScale = CGFloat(min(max(scale, 0.10), 2.40))
                let pos = CGPoint(
                    x: baseCenter.x + drift.width * driftScale
                        + CGFloat(cos(photo.angle) * screenR),
                    y: baseCenter.y + drift.height * driftScale
                        + CGFloat(sin(photo.angle) * screenR)
                )
                let w = photo.size.width * CGFloat(scale)
                let h = photo.size.height * CGFloat(scale)
                let rect = CGRect(x: pos.x - w / 2, y: pos.y - h / 2, width: w, height: h)
                projected.append(ProjectedPhoto(
                    photoID: photo.id,
                    image: photo.image,
                    rect: rect,
                    blur: dofBlur(depth),
                    opacity: opacity,
                    depth: depth,
                    layerIndex: i))
            }
        }
        return projected
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
            Divider()
            MediaCategoryMenuSection(
                selection: $mediaSelection,
                primaryAlwaysOn: true
            )
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }

    private var playButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            autoElapsed = 0
            mode = .autoPlay
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 56, height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
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
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .popover(isPresented: $settingsShown, arrowEdge: .top) {
            settingsPanel
                .presentationCompactAdaptation(.popover)
        }
    }

    private var settingsPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
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
                Text("交互")
                    .font(.headline)

                settingGroup("点击方式") {
                    Picker("", selection: Binding(
                        get: { tapMode },
                        set: { tapModeRaw = $0.rawValue }
                    )) {
                        ForEach(TunnelTapMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                settingGroup("落地出场") {
                    Picker("", selection: Binding(
                        get: { landingMotion },
                        set: { landingMotionRaw = $0.rawValue }
                    )) {
                        ForEach(TunnelLandingMotion.allCases) { Text($0.label).tag($0) }
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
                settingGroup("纵深间距") {
                    Picker("", selection: Binding(
                        get: { depthSpacing },
                        set: { applyDepthSpacing($0) }
                    )) {
                        ForEach(TunnelDepthSpacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                settingGroup("同日照片间距") {
                    Picker("", selection: Binding(
                        get: { photoDepthSpacing },
                        set: { photoDepthSpacingRaw = $0.rawValue }
                    )) {
                        ForEach(TunnelPhotoDepthSpacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                settingGroup("景深速度差") {
                    Picker("", selection: Binding(
                        get: { speedContrast },
                        set: { speedContrastRaw = $0.rawValue }
                    )) {
                        ForEach(TunnelSpeedContrast.allCases) { Text($0.label).tag($0) }
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
                settingGroup("照片模糊") {
                    Picker("", selection: Binding(
                        get: { photoBlur },
                        set: { photoBlurRaw = $0.rawValue }
                    )) {
                        ForEach(TunnelPhotoBlur.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 330, height: verticalSizeClass == .compact ? 300 : 620)
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
            BigDateView(date: displayDate, showsWeekday: false)
                .matchedGeometryEffect(id: "flowDate", in: dateNamespace, isSource: true)
                .shadow(color: background.color.opacity(0.9), radius: 14)
        }
        .allowsHitTesting(false)
    }

    private var animatedDateOverlay: some View {
        dateOverlay
            .offset(y: (1 - dateRevealProgress) * 20)
            .opacity(dateRevealProgress)
    }

    private var hintText: String {
        switch mode {
        case .autoPlay:
            return "点击屏幕，停在某一天"
        case .manualDrag, .momentum:
            return "点击进入这一天"
        case .photoZooming:
            return "即将进入这一天"
        default:
            if tapMode == .anywhere {
                return "上下滑动穿梭，或点击任意位置进入当天"
            } else {
                return "上下滑动穿梭，或点击照片进入对应天"
            }
        }
    }

    // MARK: Controls

    private func dragGesture(in size: CGSize) -> some Gesture {
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
                switch mode {
                case .manualDrag:
                    velocity = Double(-value.predictedEndTranslation.height / 150.0) * 2.2
                    mode = .momentum
                case .manualIdle:
                    if tapMode == .anywhere {
                        // Treated as a tap: enter the day currently in focus.
                        handleTap()
                    } else {
                        handlePhotoTap(at: value.location, in: size)
                    }
                default:
                    break
                }
            }
    }

    private func handleTap() {
        guard !openingIsActive, !layerDates.isEmpty,
              mode != .settling, mode != .done else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let idx = focusIndex(progress)
        pendingLandDate = layerDates[idx]
        settleTarget = snapProgress(for: idx)
        mode = .settling
    }

    /// Handle a tap in photo-tap mode: find the photo under the finger, play a
    /// quick zoom-in-then-back animation on it, then settle on its day. If the
    /// photo belongs to a different day, the tunnel first moves to that day
    /// before landing.
    private func handlePhotoTap(at point: CGPoint, in size: CGSize) {
        guard !openingIsActive, !layerDates.isEmpty,
              mode != .settling, mode != .photoZooming, mode != .done else { return }

        // Closest photos first so a tap on overlapping photos hits the front one.
        let projected = projectedPhotos(in: size)
            .filter { $0.opacity > 0.01 }
            .sorted { $0.depth < $1.depth }

        // Expand the hit area to include the white frame and a small margin.
        let hitBorder = border + 6
        guard let hit = projected.first(where: {
            $0.rect.insetBy(dx: -hitBorder, dy: -hitBorder).contains(point)
        }) else { return }

        let targetIndex = hit.layerIndex
        guard layerDates.indices.contains(targetIndex) else { return }
        let targetDate = layerDates[targetIndex]

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tappedPhotoID = hit.photoID
        mode = .photoZooming

        Task { @MainActor in
            // Zoom in
            withAnimation(.easeInOut(duration: 0.15)) {
                tappedPhotoScale = 1.08
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, mode == .photoZooming else { return }
            // Zoom back
            withAnimation(.easeInOut(duration: 0.15)) {
                tappedPhotoScale = 1.0
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, mode == .photoZooming else { return }
            // Begin tunnel travel to the target day
            tappedPhotoID = nil
            pendingLandDate = targetDate
            settleTarget = snapProgress(for: targetIndex)
            // Tick per layer crossed only when travelling forward to a deeper
            // (behind-the-focus) photo, matching the manual-shuttle feel.
            photoTapTraveling = targetIndex > focusIndex(progress)
            mode = .settling
        }
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
            updateDeviceTilt(dt)
            updateDateReveal(dt)
            updateOpeningMotion(dt)
            updateHintVisibility()
            guard !settingsShown else { continue }
            step(dt)
            updateFocus()
        }
    }

    private func step(_ dt: Double) {
        guard count > 0, !openingIsActive else { return }
        switch mode {
        case .autoPlay:
            autoElapsed += dt
            let travel = landProgress - progressStart
            let vMax = travel / max(autoDuration - rampTime * 0.5, 0.1)
            let v = vMax * smoothstep(0, rampTime, autoElapsed)
            progress += v * dt
            if progress >= landProgress {
                progress = landProgress
                pendingLandDate = layerDates.last
                settleTarget = progress
                startLandingMotion()
            }
        case .momentum:
            progress = clampTravel(progress + velocity * dt)
            velocity *= exp(-dt / 0.45)
            if abs(velocity) < 0.6 || progress <= progressStart || progress >= landProgress {
                settleTarget = snapProgress(for: focusIndex(progress))
                mode = .settling
            }
        case .settling:
            progress += (settleTarget - progress) * min(1, dt * 7)
            if abs(settleTarget - progress) < 0.004 {
                progress = settleTarget
                photoTapTraveling = false
                if pendingLandDate != nil {
                    startLandingMotion()
                } else {
                    mode = .manualIdle
                }
            }
        case .rushingOut:
            let rushTarget: Double
            let duration: Double
            if landingMotion == .slight {
                // Keep a gentle, constant forward drift for the entire day-view
                // entrance (≈400ms hand-off delay + 0.5s cover slide). Duration
                // runs slightly past the transition so motion never freezes
                // before the cover finishes rising; distance stays small so the
                // target day's photos never fully rush past the camera.
                rushTarget = settleTarget + 2.0
                duration = 1.0
            } else {
                rushTarget = landProgress + 2.0
                duration = 0.6
            }
            let rushDistance = max(rushTarget - settleTarget, 0.01)
            let speed = rushDistance / duration
            progress += speed * dt
            if progress >= rushTarget {
                progress = rushTarget
                if landingMotion == .slight {
                    // Transition already started alongside the motion; just stop.
                    mode = .done
                } else {
                    beginFinishFromSettle()
                }
            }
        case .manualDrag, .manualIdle, .photoZooming, .done:
            break
        }
    }

    private func updateFocus() {
        let idx = focusIndex(progress)
        guard idx != lastFocus, idx >= 0, idx < count else { return }
        lastFocus = idx
        if mode != .rushingOut {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                displayDate = layerDates[idx]
            }
        }
        let normalTick = mode != .settling && mode != .photoZooming && mode != .rushingOut && mode != .done
        let photoTravelTick = mode == .settling && photoTapTraveling
        if !openingIsActive, normalTick || photoTravelTick {
            SoundEffects.tick()
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55)
        }
    }

    /// Decide what happens once the tunnel has arrived at the target day.
    /// - none: hand off to the day view immediately.
    /// - slight: nudge the remaining photos forward *while* the transition plays.
    /// - rushOut: rush the photos off screen first, then transition.
    private func startLandingMotion() {
        switch landingMotion {
        case .none:
            beginFinishFromSettle()
        case .slight:
            mode = .rushingOut
            beginLandingTransition()
        case .rushOut:
            mode = .rushingOut
        }
    }

    private func beginFinishFromSettle() {
        guard mode != .done, !layerDates.isEmpty else { return }
        mode = .done
        beginLandingTransition()
    }

    /// Kick off the hand-off to the day view without stopping the frame loop, so
    /// "轻微运动" can animate the tunnel forward while the transition plays.
    private func beginLandingTransition() {
        guard !hasStartedLanding, !layerDates.isEmpty else { return }
        hasStartedLanding = true
        Task { await finish(on: pendingLandDate ?? layerDates[focusIndex(progress)]) }
    }

    // MARK: Landing

    private func finish(on date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            displayDate = day
        }
        SoundEffects.settle()

        // "轻微运动" runs the tunnel motion and the cover slide-up together, so
        // hand off immediately; other modes wait so their settle/rush shows first.
        if landingMotion != .slight {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        onLand(TunnelDayRequest(day))
    }

    // MARK: Math helpers

    private var ambientDrift: CGSize {
        CGSize(width: sin(clock * 0.55) * 12,
               height: cos(clock * 0.43) * 9)
    }

    private var combinedDrift: CGSize {
        CGSize(width: ambientDrift.width + tiltOffset.width,
               height: ambientDrift.height + tiltOffset.height)
    }

    private var openingIsActive: Bool {
        dateRevealProgress < 1 || openingActive || openingVisualProgress < 0.995
    }

    private func updateDateReveal(_ dt: Double) {
        guard clock > dateRevealDelay, dateRevealProgress < 1 else { return }
        let speed = 1.0 / dateRevealDuration
        dateRevealProgress = min(1, dateRevealProgress + speed * dt)
    }

    private func updateHintVisibility() {
        if !openingIsActive && openingEndedAt < 0 {
            openingEndedAt = clock
        }
        if !hintVisible && openingEndedAt >= 0 && clock - openingEndedAt > 1.0 {
            withAnimation(.easeInOut(duration: 0.3)) {
                hintVisible = true
            }
        }
    }

    private func updateOpeningMotion(_ dt: Double) {
        let target = openingActive ? openingTargetProgress : 1
        let speed = 1.0 / openingDuration
        if openingVisualProgress < target {
            openingVisualProgress = min(target, openingVisualProgress + speed * dt)
        }
        if !openingActive, abs(1 - openingVisualProgress) < 0.001 {
            openingVisualProgress = 1
        }
        updateOpeningHaptics()
    }

    /// Fires the same per-section soft tick as manual shuttle each time one of
    /// the initial layers cascades fully into place during the opening reveal.
    private func updateOpeningHaptics() {
        // Use `count` (layerDates.count, kept in sync via onChange) rather than
        // the `layers` property: `runLoop` runs on the struct value captured
        // when `.task` first started, whose `layers` array is still empty.
        let n = min(count, 6)
        guard n > 0 else { return }
        let batchCount = Double(n)
        let stagger = 1.0 / batchCount
        let moveSpan = openingOverlap / batchCount
        let totalSpan = (batchCount - 1) * stagger + moveSpan
        // Fire partway through each layer's motion (not at full settle): the
        // eased approach puts a layer visually in place well before its
        // localProgress reaches 1, so ticking at ~0.55 keeps haptics in sync
        // with the perceived landing instead of trailing behind it.
        let settleFraction = 0.55
        var settled = 0
        for i in 0..<n {
            let start = Double(i) * stagger / totalSpan
            let span = moveSpan / totalSpan
            let threshold = start + settleFraction * span
            if openingVisualProgress + 1e-6 >= threshold { settled += 1 }
        }
        // Keep the Taptic engine warm through the reveal; a cold generator
        // drops the first one or two impacts, which felt like missing ticks.
        if openingActive { openingImpact.prepare() }
        // Seed the baseline on the first pass. For a genuine opening (reveal
        // still active) start from zero so every layer ticks as it lands; for
        // an already-open tunnel (re-entry) seed to the current count so no
        // catch-up burst fires.
        guard openingHapticsInitialized else {
            openingHapticsInitialized = true
            settledOpeningLayers = openingActive ? 0 : settled
            return
        }
        while settledOpeningLayers < settled {
            settledOpeningLayers += 1
            SoundEffects.tick()
            playOpeningTick()
        }
    }


    /// Identical to the manual-shuttle "一节" tick so the opening reveal feels
    /// like the same soft per-section landing.
    private func playOpeningTick() {
        openingImpact.impactOccurred(intensity: 0.55)
        openingImpact.prepare()
    }

    private func startDeviceMotion() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    private func stopDeviceMotion() {
        motionManager.stopDeviceMotionUpdates()
        referenceRoll = nil
        referencePitch = nil
        tiltOffset = .zero
    }



    private func updateDeviceTilt(_ dt: Double) {
        guard let attitude = motionManager.deviceMotion?.attitude else { return }
        guard let referenceRoll, let referencePitch else {
            self.referenceRoll = attitude.roll
            self.referencePitch = attitude.pitch
            return
        }

        let roll = min(max(angleDelta(attitude.roll, referenceRoll), -0.45), 0.45)
        let pitch = min(max(angleDelta(attitude.pitch, referencePitch), -0.45), 0.45)
        let target = CGSize(width: CGFloat(-roll * 42),
                            height: CGFloat(-pitch * 42))
        let smoothing = CGFloat(1 - exp(-dt / 0.10))
        tiltOffset.width += (target.width - tiltOffset.width) * smoothing
        tiltOffset.height += (target.height - tiltOffset.height) * smoothing
    }

    private func angleDelta(_ angle: Double, _ reference: Double) -> Double {
        var delta = (angle - reference).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Preserve the current point between days when spacing changes in the live
    /// settings preview, rather than jumping the camera to another date.
    private func applyDepthSpacing(_ newSpacing: TunnelDepthSpacing) {
        let oldFactor = depthSpacing.factor
        guard newSpacing.factor != oldFactor else { return }
        let ratio = newSpacing.factor / oldFactor
        progress = (progress + focal) * ratio - focal
        settleTarget = (settleTarget + focal) * ratio - focal
        dragStartProgress = (dragStartProgress + focal) * ratio - focal
        velocity *= ratio
        depthSpacingRaw = newSpacing.rawValue
    }

    private func clampTravel(_ p: Double) -> Double {
        min(max(p, progressStart), landProgress)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 3×3 dot grid loader: 8 perimeter dots shift one step clockwise each cycle
/// while the container pulses in size. Center dot stays fixed.
private struct TunnelLoader: View {
    private let dotSize: CGFloat = 4
    private let minSize: CGFloat = 16
    private let maxSize: CGFloat = 24
    private let color: Color = .gray

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: 1.0)

                // Size pulse: 0-35% expand, 35-65% hold, 65-100% shrink
                let sizeP: Double
                if phase < 0.35 {
                    sizeP = smoothstep(phase / 0.35)
                } else if phase < 0.65 {
                    sizeP = 1
                } else {
                    sizeP = 1 - smoothstep((phase - 0.65) / 0.35)
                }
                let w = Double(minSize) + Double(maxSize - minSize) * sizeP

                // Position shift: 0-40% at A, 40-60% transition, 60-100% at B
                let shiftP: Double
                if phase < 0.4 {
                    shiftP = 0
                } else if phase < 0.6 {
                    shiftP = smoothstep((phase - 0.4) / 0.2)
                } else {
                    shiftP = 1
                }

                // Perimeter positions (counter-clockwise from top-left)
                let posA: [(Double, Double)] = [
                    (0, 0), (0, 0.5), (0, 1), (0.5, 1),
                    (1, 1), (1, 0.5), (1, 0), (0.5, 0)
                ]
                let posB: [(Double, Double)] = [
                    (0, 0.5), (0, 1), (0.5, 1), (1, 1),
                    (1, 0.5), (1, 0), (0.5, 0), (0, 0)
                ]

                let d = Double(dotSize)
                let span = w - d
                let offX = (Double(size.width) - w) / 2
                let offY = (Double(size.height) - w) / 2

                for i in 0..<8 {
                    let (ax, ay) = posA[i]
                    let (bx, by) = posB[i]
                    let x = (ax + (bx - ax) * shiftP) * span + offX
                    let y = (ay + (by - ay) * shiftP) * span + offY
                    context.fill(
                        Path(CGRect(x: x, y: y, width: d, height: d)),
                        with: .color(color)
                    )
                }

                // Center dot
                let cx = (Double(size.width) - d) / 2
                let cy = (Double(size.height) - d) / 2
                context.fill(
                    Path(CGRect(x: cx, y: cy, width: d, height: d)),
                    with: .color(color)
                )
            }
            .frame(width: maxSize, height: maxSize)
        }
    }

    private func smoothstep(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
}
