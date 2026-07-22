import SwiftUI
import Photos
import CoreLocation

@MainActor
@Observable
final class DayViewModel {
    let instanceID = UUID()
    let date: Date
    private(set) var sections: [MagazineSection]
    private(set) var allItems: [PhotoItem]
    var selected: PhotoItem?

    private var favoriteIDs: Set<String>
    var albumPickerItem: PhotoItem?

    // Free-canvas arrangement: per-block offsets applied when drag mode is on.
    var isDragEnabled = false
    var blockOffsets: [UUID: CGSize] = [:]

    // MARK: Page appearance
    private static let backgroundKey   = "OneDay.pageBackground"
    private static let borderWidthKey  = "OneDay.borderWidth"
    private static let borderStyleKey  = "OneDay.borderStyle"
    private static let enabledTemplatesKey = "OneDay.enabledTemplates"
    // MARK: Scroll animation
    private static let scrollScaleKey    = "OneDay.scrollScale"
    private static let scrollMovementKey = "OneDay.scrollMovement"
    private static let scrollRotationKey = "OneDay.scrollRotation"
    private static let scrollFadeKey     = "OneDay.scrollFade"
    private static let scrollSpringKey   = "OneDay.scrollSpring"
    private static let scrollStaggerKey  = "OneDay.scrollStagger"
    private static let scrollBlurKey     = "OneDay.scrollBlur"
    private static let scrollParallaxKey = "OneDay.scrollParallax"
    private static let scrollTiltXKey    = "OneDay.scrollTiltX"
    private static let scrollTiltYKey    = "OneDay.scrollTiltY"
    private static let scrollTiltDecayKey = "OneDay.scrollTiltDecay"
    private static let pageFlipModeKey   = "OneDay.pageFlipMode"
    private static let staggeredTopLiftKey = "OneDay.staggeredTopLift"
    private static let coverDateFontKey  = "OneDay.coverDateFont"
    private static let sectionTintKey    = "OneDay.sectionTint"
    private static let locationBarKey    = "OneDay.locationBar"

    var background: PageBackground {
        didSet {
            UserDefaults.standard.set(background.rawValue, forKey: Self.backgroundKey)
            Task { await computeSectionTints() }
        }
    }
    var borderWidth: PhotoBorderWidth {
        didSet { UserDefaults.standard.set(borderWidth.rawValue, forKey: Self.borderWidthKey) }
    }
    var borderStyle: PhotoBorderStyle {
        didSet {
            UserDefaults.standard.set(borderStyle.rawValue, forKey: Self.borderStyleKey)
            if borderStyle == .colored { Task { await computeFrameColors() } }
        }
    }
    var enabledTemplates: Set<BlockTemplate> {
        didSet {
            let raw = enabledTemplates.map(\.rawValue).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: Self.enabledTemplatesKey)
            recompose()
        }
    }
    var scrollScale: ScrollScaleMagnitude {
        didSet { UserDefaults.standard.set(scrollScale.rawValue,    forKey: Self.scrollScaleKey) }
    }
    var scrollMovement: ScrollMovement {
        didSet { UserDefaults.standard.set(scrollMovement.rawValue, forKey: Self.scrollMovementKey) }
    }
    var scrollRotation: ScrollRotation {
        didSet { UserDefaults.standard.set(scrollRotation.rawValue, forKey: Self.scrollRotationKey) }
    }
    var scrollFade: ScrollFade {
        didSet { UserDefaults.standard.set(scrollFade.rawValue,     forKey: Self.scrollFadeKey) }
    }
    var scrollSpring: ScrollSpring {
        didSet { UserDefaults.standard.set(scrollSpring.rawValue,   forKey: Self.scrollSpringKey) }
    }
    var scrollStagger: ScrollStagger {
        didSet { UserDefaults.standard.set(scrollStagger.rawValue,  forKey: Self.scrollStaggerKey) }
    }
    var scrollBlur: ScrollBlur {
        didSet { UserDefaults.standard.set(scrollBlur.rawValue,     forKey: Self.scrollBlurKey) }
    }
    var scrollParallax: ScrollParallax {
        didSet { UserDefaults.standard.set(scrollParallax.rawValue, forKey: Self.scrollParallaxKey) }
    }
    var scrollTiltX: ScrollTiltX {
        didSet { UserDefaults.standard.set(scrollTiltX.rawValue,    forKey: Self.scrollTiltXKey) }
    }
    var scrollTiltY: ScrollTiltY {
        didSet { UserDefaults.standard.set(scrollTiltY.rawValue,    forKey: Self.scrollTiltYKey) }
    }
    var scrollTiltDecay: ScrollTiltDecay {
        didSet { UserDefaults.standard.set(scrollTiltDecay.rawValue, forKey: Self.scrollTiltDecayKey) }
    }
    var pageFlipMode: PageFlipMode {
        didSet { UserDefaults.standard.set(pageFlipMode.rawValue, forKey: Self.pageFlipModeKey) }
    }
    var staggeredTopLiftEnabled: Bool {
        didSet { UserDefaults.standard.set(staggeredTopLiftEnabled, forKey: Self.staggeredTopLiftKey) }
    }
    var coverDateFont: CoverDateFont {
        didSet { UserDefaults.standard.set(coverDateFont.rawValue, forKey: Self.coverDateFontKey) }
    }
    /// When on (and background is a photo-derived color), each headline section
    /// gets its own tint pulled from that section's photos.
    var sectionTintEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sectionTintEnabled, forKey: Self.sectionTintKey)
            Task { await computeSectionTints() }
        }
    }
    /// Whether the location toolbar at the top of the photo page is shown.
    var showLocationBar: Bool {
        didSet { UserDefaults.standard.set(showLocationBar, forKey: Self.locationBarKey) }
    }
    // MARK: Cover / back cover state
    private(set) var coverPhotos: [PhotoItem] = []
    private(set) var personStickers: [PersonSticker] = []
    private(set) var coverBackgroundColor: Color = Color(white: 0.96)
    private var coverBackgroundIsDark = false
    private(set) var backCoverBackgroundColor: Color = Color(white: 0.12)
    private var backCoverIsDark = true

    var coverColorScheme: ColorScheme {
        coverBackgroundIsDark ? .dark : .light
    }
    var backCoverColorScheme: ColorScheme {
        backCoverIsDark ? .dark : .light
    }

    /// Editorial summary for the back cover.
    var backCoverSummary: BackCoverSummary {
        BackCoverSummary(
            photoCount: photoCount,
            videoCount: videoCount,
            kilometers: travelKilometers,
            places: headerPlaces
        )
    }
    private var photoFrameColors: [String: Color] = [:]
    private(set) var warmColor: Color    = Color(red: 0.93, green: 0.78, blue: 0.62)
    private(set) var dominantColor: Color = Color(white: 0.5)
    private(set) var vibrantColor: Color  = Color(white: 0.5)
    private(set) var brightColor: Color   = Color(white: 0.95)
    private(set) var bright2Color: Color  = Color(white: 1.0)
    private var dominantIsDark = false
    private var vibrantIsDark  = false
    // bright modes are always light, so no isDark flag is needed.

    var pageBackgroundColor: Color {
        switch background {
        case .paper:    return Color(white: 0.96)
        case .dark:     return Color(white: 0.07)
        case .warm:     return warmColor
        case .dominant: return dominantColor
        case .vibrant:  return vibrantColor
        case .bright:   return brightColor
        case .bright2:  return bright2Color
        }
    }

    var pageColorScheme: ColorScheme {
        switch background {
        case .dark:     return .dark
        case .dominant: return dominantIsDark ? .dark : .light
        case .vibrant:  return vibrantIsDark  ? .dark : .light
        case .bright:   return .light
        case .bright2:  return .light
        default:        return .light
        }
    }

    /// Creates a bright, airy tint from a photo hue: high fixed brightness with
    /// a moderate saturation so the color stays light and readable. (明快1)
    private func brightTint(h: CGFloat, s: CGFloat) -> (Color, Bool) {
        let sat = max(min(s * 1.25, 0.58), 0.42)
        let color = UIColor(hue: h, saturation: sat, brightness: 0.95, alpha: 1)
        return (Color(uiColor: color), false)
    }

    /// Even lighter, near-white wash: full brightness with a low saturation so
    /// the page reads as a faint pastel. (明快2)
    private func bright2Tint(h: CGFloat, s: CGFloat) -> (Color, Bool) {
        let sat = max(min(s, 0.3), 0.2)
        let color = UIColor(hue: h, saturation: sat, brightness: 1.0, alpha: 1)
        return (Color(uiColor: color), false)
    }

    init(date: Date, items: [PhotoItem]) {
        self.date = date
        self.allItems = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        self.favoriteIDs = Set(items.filter { $0.isFavorite }.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Self.backgroundKey)
        self.background = PageBackground(rawValue: saved ?? "") ?? .paper
        let savedWidth = UserDefaults.standard.string(forKey: Self.borderWidthKey)
        self.borderWidth = PhotoBorderWidth(rawValue: savedWidth ?? "") ?? .max
        let savedStyle = UserDefaults.standard.string(forKey: Self.borderStyleKey)
        self.borderStyle = PhotoBorderStyle(rawValue: savedStyle ?? "") ?? .white
        self.scrollScale    = ScrollScaleMagnitude(rawValue: UserDefaults.standard.string(forKey: Self.scrollScaleKey)    ?? "") ?? .strong
        self.scrollMovement = ScrollMovement(rawValue:       UserDefaults.standard.string(forKey: Self.scrollMovementKey) ?? "") ?? .large
        self.scrollRotation = ScrollRotation(rawValue:       UserDefaults.standard.string(forKey: Self.scrollRotationKey) ?? "") ?? .medium
        self.scrollFade     = ScrollFade(rawValue:           UserDefaults.standard.string(forKey: Self.scrollFadeKey)     ?? "") ?? .hidden
        self.scrollSpring   = ScrollSpring(rawValue:         UserDefaults.standard.string(forKey: Self.scrollSpringKey)   ?? "") ?? .standard
        self.scrollStagger  = ScrollStagger(rawValue:        UserDefaults.standard.string(forKey: Self.scrollStaggerKey)  ?? "") ?? .none
        self.scrollBlur     = ScrollBlur(rawValue:           UserDefaults.standard.string(forKey: Self.scrollBlurKey)     ?? "") ?? .none
        self.scrollParallax = ScrollParallax(rawValue:       UserDefaults.standard.string(forKey: Self.scrollParallaxKey) ?? "") ?? .none
        self.scrollTiltX    = ScrollTiltX(rawValue:          UserDefaults.standard.string(forKey: Self.scrollTiltXKey)    ?? "") ?? .none
        self.scrollTiltY    = ScrollTiltY(rawValue:          UserDefaults.standard.string(forKey: Self.scrollTiltYKey)    ?? "") ?? .none
        self.scrollTiltDecay = ScrollTiltDecay(rawValue:     UserDefaults.standard.string(forKey: Self.scrollTiltDecayKey) ?? "") ?? .linear
        self.pageFlipMode = PageFlipMode(rawValue:           UserDefaults.standard.string(forKey: Self.pageFlipModeKey)   ?? "") ?? .snapParallax
        self.staggeredTopLiftEnabled = UserDefaults.standard.object(forKey: Self.staggeredTopLiftKey) as? Bool ?? true
        self.coverDateFont = CoverDateFont(rawValue:         UserDefaults.standard.string(forKey: Self.coverDateFontKey)  ?? "") ?? .impact
        self.sectionTintEnabled = UserDefaults.standard.object(forKey: Self.sectionTintKey) as? Bool ?? false
        self.showLocationBar = UserDefaults.standard.object(forKey: Self.locationBarKey) as? Bool ?? true
        // Enabled templates must be loaded before composing sections
        let rawTpl = UserDefaults.standard.string(forKey: Self.enabledTemplatesKey) ?? ""
        let loadedTpl = Set(rawTpl.split(separator: ",").compactMap { BlockTemplate(rawValue: String($0)) })
        let tplSet: Set<BlockTemplate> = loadedTpl.isEmpty
            ? Set(BlockTemplate.allCases.filter { $0.isSelectable })
            : loadedTpl
        self.enabledTemplates = tplSet
        // Use local tplSet to avoid accessing self before sections is initialized
        self.sections = MagazineLayoutEngine.compose(items, enabled: tplSet)
    }

    var photoCount: Int { allItems.filter { !$0.isVideo }.count }
    var videoCount: Int { allItems.filter(\.isVideo).count }
    var layoutConfig: LayoutConfig {
        var c = LayoutConfig.make(itemCount: allItems.count)
        c.borderScale    = borderWidth.scale
        c.borderStyle    = borderStyle
        c.staggerFactor  = scrollStagger.factor
        return c
    }

    /// Vision similarity distances between consecutive items, populated by
    /// `applyVisionGrouping`. Kept so sections can be rebuilt (template toggles,
    /// place/time switch) without recomputing Vision.
    private var visionDistances: [String: Float] = [:]

    private func visionSimilar(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        let gap = abs((a.creationDate ?? .distantPast)
            .timeIntervalSince(b.creationDate ?? .distantPast))
        guard gap <= 8 * 60 else { return false }
        if let d = visionDistances["\(a.id)|\(b.id)"] { return d < 0.62 }
        return false
    }

    /// Ordered place groups covering every item. Located items define the stop
    /// boundaries; non-located items attach to the current stop chronologically
    /// so nothing is dropped.
    private func placeGroups() -> [(name: String?, items: [PhotoItem])] {
        let stops = routeStops
        guard !stops.isEmpty else { return [] }
        var stopOfItem: [String: Int] = [:]
        for (i, stop) in stops.enumerated() {
            for id in stop.itemIDs { stopOfItem[id] = i }
        }
        var groups: [[PhotoItem]] = Array(repeating: [], count: stops.count)
        var current = 0
        for item in allItems {
            if let idx = stopOfItem[item.id] { current = idx }
            groups[current].append(item)
        }
        return zip(stops, groups).map { ($0.name, $1) }
    }

    /// Rebuilds `sections` choosing place-based grouping when the day spans
    /// multiple places, otherwise the default time-band grouping.
    private func rebuildSections(animated: Bool = true) {
        let similar: ((PhotoItem, PhotoItem) -> Bool)? =
            visionDistances.isEmpty ? nil : { [weak self] a, b in
                self?.visionSimilar(a, b) ?? false
            }
        let newSections: [MagazineSection]
        if hasRoute {
            newSections = MagazineLayoutEngine.composeByPlace(
                groups: placeGroups(), similar: similar, enabled: enabledTemplates)
        } else {
            newSections = MagazineLayoutEngine.compose(
                allItems, similar: similar, enabled: enabledTemplates)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { sections = newSections }
        } else {
            sections = newSections
        }
        Task { await computeSectionTints() }
    }

    /// Recomposes sections using the current enabledTemplates.
    private func recompose() {
        rebuildSections(animated: true)
    }

    /// Returns the frame color for a photo based on the current border style.
    func frameColor(for item: PhotoItem) -> Color {
        switch borderStyle {
        case .white:    return Theme.frame
        case .black:    return .black
        case .colored:  return photoFrameColors[item.id] ?? Theme.frame
        case .polaroid: return Theme.frame
        }
    }

    // MARK: Preparation (Vision similarity + places + warm color)

    func prepare() async {
        await computeWarmColor()
        await applyVisionGrouping()
        await resolveSegmentNames()
        rebuildSections()
        await resolvePlaces()
        if borderStyle == .colored { await computeFrameColors() }
        await computeCoverPhotos()
        await computeCoverBackgroundColor()
        await computePersonStickers()
    }

    /// Extracts a vivid-but-soft tint color from each photo’s thumbnail for use as a frame.
    private func computeFrameColors() async {
        let photos = allItems.filter { !$0.isVideo }.prefix(40)
        for item in photos where photoFrameColors[item.id] == nil {
            guard let img = await ImageLoader.shared.thumbnail(asset: item.asset,
                                                              size: CGSize(width: 48, height: 48)),
                  let base = img.averageColor else { continue }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            // Boost saturation slightly; keep brightness high for a vivid but not harsh frame.
            let tinted = UIColor(hue: h,
                                 saturation: min(s * 1.4, 0.70),
                                 brightness: max(min(b * 1.1, 0.95), 0.72),
                                 alpha: 1)
            photoFrameColors[item.id] = Color(uiColor: tinted)
        }
    }

    private func computeWarmColor() async {
        guard let first = allItems.first(where: { !$0.isVideo }) ?? allItems.first else { return }
        guard let image = await ImageLoader.shared.thumbnail(asset: first.asset,
                                                            size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Warm: blend the photo's hue toward an orange family, kept light to read on.
        let orange: CGFloat = 0.07
        let blendedHue = h * 0.4 + orange * 0.6
        let warm = UIColor(hue: blendedHue,
                           saturation: max(min(s, 0.55), 0.30),
                           brightness: 0.90, alpha: 1)

        // Dominant: the photo's own color, lightly toned for a full-page background.
        let dominant = UIColor(hue: h,
                               saturation: min(s, 0.6),
                               brightness: max(min(b, 0.92), 0.18), alpha: 1)
        let isDark = min(b, 0.92) < 0.5

        // Vibrant: same hue, forced-high saturation regardless of the source photo's greyness.
        let vSat = max(min(s * 2.5, 0.95), 0.75)  // floor 0.75 so even grey photos pop
        let vBri = max(min(b, 0.90), 0.52)          // keep bright enough to look vivid
        let vibrant = UIColor(hue: h, saturation: vSat, brightness: vBri, alpha: 1)
        let vIsDark = vBri < 0.5

        // Bright: airy, light tint with a fixed high brightness and moderate saturation.
        let (bright, _) = brightTint(h: h, s: s)
        // Bright2: near-white pastel wash, full brightness with low saturation.
        let (bright2, _) = bright2Tint(h: h, s: s)

        withAnimation(.easeInOut(duration: 0.3)) {
            warmColor     = Color(uiColor: warm)
            dominantColor = Color(uiColor: dominant)
            vibrantColor  = Color(uiColor: vibrant)
            brightColor   = bright
            bright2Color  = bright2
            dominantIsDark = isDark
            vibrantIsDark  = vIsDark
        }
    }

    // MARK: Cover

    /// Picks the 2 sharpest/best-composed non-video photos for the cover.
    private func computeCoverPhotos() async {
        let photos = allItems.filter { !$0.isVideo }
        guard !photos.isEmpty else { coverPhotos = []; return }
        if photos.count <= 2 { coverPhotos = photos; return }
        let ranked = await PhotoSharpnessRanker.shared.rank(photos, top: 2)
        coverPhotos = ranked
    }

    /// Cover & back-cover backgrounds (method B: hue rotation off the hero
    /// photo). The photo page keeps the hero's own hue (dominant/vibrant); the
    /// cover shifts +30° (analogous, kept light & vivid) and the back cover
    /// shifts +180° (complementary, a deeper editorial tone). The rotations
    /// guarantee both differ from the page's main hue.
    private func computeCoverBackgroundColor() async {
        guard let hero = coverPhotos.first,
              let image = await ImageLoader.shared.thumbnail(
                asset: hero.asset, size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else {
            withAnimation(.easeInOut(duration: 0.3)) {
                coverBackgroundColor = warmColor
                coverBackgroundIsDark = false
                backCoverBackgroundColor = Color(white: 0.12)
                backCoverIsDark = true
            }
            return
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // Cover: analogous +30°, light and vivid.
        let (cover, coverDark) = rotatedColor(
            baseHue: h, baseSat: s, baseBri: b,
            hueShift: 30.0 / 360.0, satFloor: 0.62, satScale: 2.3,
            briScale: 1.06, briRange: 0.60...0.92)
        // Back cover: complementary +180°, deeper.
        let (back, backDark) = rotatedColor(
            baseHue: h, baseSat: s, baseBri: b,
            hueShift: 0.5, satFloor: 0.5, satScale: 2.0,
            briScale: 0.82, briRange: 0.28...0.60)

        withAnimation(.easeInOut(duration: 0.3)) {
            coverBackgroundColor = cover
            coverBackgroundIsDark = coverDark
            backCoverBackgroundColor = back
            backCoverIsDark = backDark
        }
    }

    /// Builds an HSB color with the hue rotated by `hueShift` (0...1 turns) and
    /// saturation/brightness pushed into an editorial range.
    private func rotatedColor(baseHue h: CGFloat, baseSat s: CGFloat, baseBri b: CGFloat,
                              hueShift: CGFloat, satFloor: CGFloat, satScale: CGFloat,
                              briScale: CGFloat, briRange: ClosedRange<CGFloat>) -> (Color, Bool) {
        var hue = (h + hueShift).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        let sat = max(min(s * satScale, 0.92), satFloor)
        let bri = min(max(b * briScale, briRange.lowerBound), briRange.upperBound)
        let color = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        return (Color(uiColor: color), bri < 0.5)
    }

    /// Extracts up to 2 distinct person stickers (transparent foreground + white outline).
    private func computePersonStickers() async {
        let photos = allItems.filter { !$0.isVideo }
        guard !photos.isEmpty else { personStickers = []; return }
        // Scan the cover photos first (most likely to contain the day's people),
        // then the rest chronologically.
        let coverIDs = Set(coverPhotos.map(\.id))
        let ordered = coverPhotos + photos.filter { !coverIDs.contains($0.id) }
        let stickers = await PersonStickerExtractor.shared.extract(from: ordered, max: 2)
        personStickers = stickers
    }

    /// True when at least one located photo/video exists (map is worth showing).
    var hasAnyLocation: Bool { !routeLocations.isEmpty }

    /// Background color derived from a specific photo, matching the current
    /// `background` setting. Returns nil for non-photo backgrounds (paper/dark/
    /// warm) so the caller keeps the static `pageBackgroundColor`. Used by the
    /// preview to track the currently viewed photo's dominant/vibrant tint.
    func photoDerivedBackground(for item: PhotoItem) async -> Color? {
        guard background == .dominant || background == .vibrant || background == .bright || background == .bright2 else { return nil }
        guard let image = await ImageLoader.shared.thumbnail(
                asset: item.asset, size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch background {
        case .dominant:
            let dominant = UIColor(hue: h, saturation: min(s, 0.6),
                                   brightness: max(min(b, 0.92), 0.18), alpha: 1)
            return Color(uiColor: dominant)
        case .vibrant:
            let vSat = max(min(s * 2.5, 0.95), 0.75)
            let vBri = max(min(b, 0.90), 0.52)
            return Color(uiColor: UIColor(hue: h, saturation: vSat, brightness: vBri, alpha: 1))
        case .bright:
            return brightTint(h: h, s: s).0
        case .bright2:
            return bright2Tint(h: h, s: s).0
        default:
            return nil
        }
    }

    // MARK: Per-section tint

    /// Average color of each section's hero photo, keyed by photo id (stable
    /// across section rebuilds).
    private var photoAverageColors: [String: UIColor] = [:]
    /// Pre-computed hue for each section in `.bright`/`.bright2` mode, with
    /// adjacent hue collision avoidance so segments remain distinct.
    private var sectionBrightHue: [String: CGFloat] = [:]

    /// True when per-section tinting should be applied.
    var sectionTintActive: Bool {
        sectionTintEnabled && (background == .dominant || background == .vibrant || background == .bright || background == .bright2)
    }

    /// Loads the average color of each section's hero photo so `sectionBackgroundColor`
    /// can resolve synchronously.
    private func computeSectionTints() async {
        guard sectionTintActive else { return }
        for section in sections {
            guard let hero = section.heroItem, photoAverageColors[hero.id] == nil else { continue }
            if let image = await ImageLoader.shared.thumbnail(
                    asset: hero.asset, size: CGSize(width: 48, height: 48)),
               let base = image.averageColor {
                photoAverageColors[hero.id] = base
            }
        }
        await computeBrightSectionHues()
    }

    /// Computes hue-adjusted tints for the `.bright`/`.bright2` backgrounds so
    /// that adjacent sections do not land on nearly the same color.
    private func computeBrightSectionHues() async {
        guard background == .bright || background == .bright2 else { return }
        sectionBrightHue.removeAll()
        var previousHue: CGFloat? = nil
        let hueThreshold: CGFloat = 1.0 / 12.0  // 30°
        for section in sections {
            guard let hero = section.heroItem,
                  let base = photoAverageColors[hero.id] else { continue }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if let prev = previousHue {
                var distance = abs(h - prev)
                distance = min(distance, 1 - distance)
                if distance < hueThreshold {
                    h = (prev + hueThreshold + 0.02).truncatingRemainder(dividingBy: 1)
                    if h < 0 { h += 1 }
                }
            }
            sectionBrightHue[hero.id] = h
            previousHue = h
        }
    }

    /// Derives a tint from a base color using the current photo-background mode.
    private func tint(from base: UIColor) -> (Color, Bool) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        switch background {
        case .vibrant:
            let vSat = max(min(s * 2.5, 0.95), 0.75)
            let vBri = max(min(b, 0.90), 0.52)
            return (Color(uiColor: UIColor(hue: h, saturation: vSat, brightness: vBri, alpha: 1)), vBri < 0.5)
        case .bright:
            return brightTint(h: h, s: s)
        case .bright2:
            return bright2Tint(h: h, s: s)
        default: // .dominant
            let bri = max(min(b, 0.92), 0.18)
            return (Color(uiColor: UIColor(hue: h, saturation: min(s, 0.6), brightness: bri, alpha: 1)), bri < 0.5)
        }
    }

    func sectionBackgroundColor(_ section: MagazineSection) -> Color {
        guard sectionTintActive, let hero = section.heroItem else { return pageBackgroundColor }
        if background == .bright || background == .bright2 {
            guard let hue = sectionBrightHue[hero.id] ?? photoAverageColors[hero.id]?.hsbHue else { return pageBackgroundColor }
            guard let base = photoAverageColors[hero.id] else { return pageBackgroundColor }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if background == .bright2 {
                return bright2Tint(h: hue, s: s).0
            }
            return brightTint(h: hue, s: s).0
        }
        guard let base = photoAverageColors[hero.id] else { return pageBackgroundColor }
        return tint(from: base).0
    }

    func sectionColorScheme(_ section: MagazineSection) -> ColorScheme {
        guard sectionTintActive, let hero = section.heroItem else { return pageColorScheme }
        if background == .bright || background == .bright2 { return .light }
        guard let base = photoAverageColors[hero.id] else { return pageColorScheme }
        return tint(from: base).1 ? .dark : .light
    }

    private func applyVisionGrouping() async {
        guard allItems.count > 1 else { return }
        await VisionSimilarity.shared.warmUp(Array(allItems.prefix(150)))

        // Precompute Vision distances between consecutive items.
        var distances: [String: Float] = [:]
        for i in 1..<allItems.count {
            let a = allItems[i - 1], b = allItems[i]
            if let d = await VisionSimilarity.shared.distance(a, b) {
                distances["\(a.id)|\(b.id)"] = d
            }
        }
        visionDistances = distances
        rebuildSections()
    }

    // MARK: Route

    /// Distance (m) beyond which a photo is treated as a new place stop.
    private static let placeThreshold: CLLocationDistance = 200

    /// A chronological route stop: a geographic cluster of located items. Built
    /// purely from coordinates so it stays consistent with the map and is not
    /// affected by time-band sectioning. Revisits appear as separate stops.
    struct RouteSegment: Identifiable {
        let id: String              // earliest item id in the segment (stable)
        let firstItemID: String     // earliest item, used as the scroll target
        let coordinate: CLLocationCoordinate2D
        let itemIDs: [String]
    }

    private var segmentNames: [String: String] = [:]

    /// Real trajectory: every located photo/video in chronological order.
    var routeLocations: [CLLocation] {
        allItems.compactMap(\.location)
    }

    /// Geographic clustering of located items into ordered stops (route mode:
    /// a returning location yields a new stop). A new stop starts when an item
    /// is farther than `placeThreshold` from the running centroid of the
    /// current stop.
    var routeSegments: [RouteSegment] {
        let located = allItems.filter { $0.location != nil }
        guard !located.isEmpty else { return [] }

        var segments: [RouteSegment] = []
        var ids: [String] = []
        var first: PhotoItem?
        var sumLat = 0.0, sumLon = 0.0

        func centroid() -> CLLocation {
            let n = Double(ids.count)
            return CLLocation(latitude: sumLat / n, longitude: sumLon / n)
        }
        func flush() {
            guard let first else { return }
            segments.append(RouteSegment(id: first.id, firstItemID: first.id,
                                         coordinate: centroid().coordinate, itemIDs: ids))
        }
        func reset() { ids = []; first = nil; sumLat = 0; sumLon = 0 }
        func add(_ item: PhotoItem, _ loc: CLLocation) {
            if first == nil { first = item }
            ids.append(item.id)
            sumLat += loc.coordinate.latitude
            sumLon += loc.coordinate.longitude
        }

        for item in located {
            guard let loc = item.location else { continue }
            if !ids.isEmpty, loc.distance(from: centroid()) > Self.placeThreshold {
                flush(); reset()
            }
            add(item, loc)
        }
        flush()
        return segments
    }

    /// A displayed route stop. Consecutive segments that resolve to the exact
    /// same place name are merged into one stop.
    struct RouteStop: Identifiable {
        let id: String
        let name: String?
        let firstItemID: String
        let itemIDs: [String]
    }

    var routeStops: [RouteStop] {
        var stops: [RouteStop] = []
        for segment in routeSegments {
            let name = segmentNames[segment.id]
            if let last = stops.last, let lastName = last.name, let name, lastName == name {
                stops[stops.count - 1] = RouteStop(id: last.id, name: last.name,
                                                   firstItemID: last.firstItemID,
                                                   itemIDs: last.itemIDs + segment.itemIDs)
            } else {
                stops.append(RouteStop(id: segment.id, name: name,
                                       firstItemID: segment.firstItemID,
                                       itemIDs: segment.itemIDs))
            }
        }
        return stops
    }

    var hasRoute: Bool { routeStops.count >= 2 }

    /// Scroll anchor (block id) for a stop: the block holding its earliest photo.
    func scrollTarget(for stop: RouteStop) -> UUID? {
        for section in sections {
            for block in section.blocks where block.items.contains(where: { $0.id == stop.firstItemID }) {
                return block.id
            }
        }
        return nil
    }

    /// Which displayed stop a block belongs to (by its first item that maps to a
    /// stop), used to sync the selector's highlight to the scrolled position.
    func stopID(forBlockID blockID: UUID) -> String? {
        let stops = routeStops
        for section in sections {
            for block in section.blocks where block.id == blockID {
                for item in block.items {
                    if let stop = stops.first(where: { $0.itemIDs.contains(item.id) }) {
                        return stop.id
                    }
                }
                return nil
            }
        }
        return nil
    }

    private func resolveSegmentNames() async {
        for segment in routeSegments where segmentNames[segment.id] == nil {
            let loc = CLLocation(latitude: segment.coordinate.latitude,
                                 longitude: segment.coordinate.longitude)
            if let name = await LocationResolver.shared.name(for: loc) {
                segmentNames[segment.id] = name
            }
        }
    }

    /// Total travel distance along the trajectory, in kilometers.
    var travelKilometers: Double {
        let locations = routeLocations
        guard locations.count >= 2 else { return 0 }
        var meters: CLLocationDistance = 0
        for i in 1..<locations.count {
            meters += locations[i].distance(from: locations[i - 1])
        }
        return meters / 1000
    }

    // MARK: Favorites

    func isFavorite(_ item: PhotoItem) -> Bool {
        favoriteIDs.contains(item.id)
    }

    func toggleFavorite(_ item: PhotoItem) async {
        let next = !favoriteIDs.contains(item.id)
        do {
            try await PhotoActionService.shared.setFavorite(next, on: item.asset)
            if next { favoriteIDs.insert(item.id) } else { favoriteIDs.remove(item.id) }
        } catch {
            // permission denied or cancelled; keep UI state unchanged
        }
    }

    // MARK: Albums

    func userAlbums() -> [AlbumInfo] {
        PhotoActionService.shared.userAlbums()
    }

    func addToAlbum(_ album: AlbumInfo, item: PhotoItem) async {
        try? await PhotoActionService.shared.addToAlbum(identifier: album.id, assets: [item.asset])
    }

    func createAlbum(named name: String, item: PhotoItem) async {
        try? await PhotoActionService.shared.addToAlbum(named: name, assets: [item.asset])
    }

    var headerPlaces: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for section in sections {
            if let place = section.placeName, !seen.contains(place) {
                seen.insert(place)
                result.append(place)
            }
        }
        return result
    }

    func resolvePlaces() async {
        // In place mode each section already carries its stop's resolved name.
        guard !hasRoute else { return }
        for index in sections.indices {
            guard let location = sections[index].anchorLocation else { continue }
            if let name = await LocationResolver.shared.name(for: location) {
                sections[index].placeName = name
            }
        }
    }

    func perform(_ action: LibraryAction, on item: PhotoItem) async {
        switch action {
        case .toggleFavorite:
            await toggleFavorite(item)
        case .delete:
            do {
                try await PhotoActionService.shared.delete([item.asset])
                remove(item)
            } catch { }
        case .addToAlbum(let name):
            try? await PhotoActionService.shared.addToAlbum(named: name, assets: [item.asset])
        case .pickAlbum:
            albumPickerItem = item
        }
    }

    private func remove(_ item: PhotoItem) {
        allItems.removeAll { $0.id == item.id }
        for index in sections.indices {
            for blockIndex in sections[index].blocks.indices {
                sections[index].blocks[blockIndex].items.removeAll { $0.id == item.id }
            }
            sections[index].blocks.removeAll { $0.items.isEmpty }
        }
    }
}

// MARK: - Back cover summary

struct BackCoverSummary: Equatable {
    let photoCount: Int
    let videoCount: Int
    let kilometers: Double
    let places: [String]

    var hasRoute: Bool { kilometers >= 0.05 }
    var distanceText: String {
        if kilometers >= 1 { return String(format: "%.1f 公里", kilometers) }
        if kilometers >= 0.05 { return String(format: "%.0f 米", kilometers * 1000) }
        return "未远行"
    }
}

// MARK: - HSB helpers

private extension UIColor {
    /// Returns the hue component of this color, or nil if the color is not in RGB/HSB color space.
    var hsbHue: CGFloat? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return h
    }
}
