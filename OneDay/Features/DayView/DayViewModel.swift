import SwiftUI
import Photos
import CoreLocation

enum CoverMode: String, CaseIterable {
    case collage    // 拼贴（现有）
    case scattered  // 散布（新增）

    var label: String { self == .collage ? "拼贴" : "散布" }
}

enum SectionTitleSize: String, CaseIterable, Identifiable {
    case xsmall, small, medium, large, xlarge
    var id: String { rawValue }
    var label: String { ["最小", "较小", "适中", "较大", "最大"][Self.allCases.firstIndex(of: self) ?? 4] }
    var size: CGFloat { [32, 38, 44, 50, 56][Self.allCases.firstIndex(of: self) ?? 4] }
}

struct ScatteredCoverPhoto: Identifiable {
    let id: String
    let item: PhotoItem
    let angle: Double      // radians, tube-wall angle
    let radius: Double     // 0...1
    let baseSize: CGSize   // base display size
}

@MainActor
@Observable
final class DayViewModel {
    let instanceID = UUID()
    let date: Date
    private(set) var sections: [MagazineSection]
    private(set) var allItems: [PhotoItem]
    var selected: PhotoItem?
    /// The photo currently being viewed inside the preview. Drives the hero
    /// fly-back so closing returns to the photo on screen now (requirement B).
    var previewCurrentID: String?

    private var favoriteIDs: Set<String>
    private var hiddenIDs: Set<String>
    var albumPickerItem: PhotoItem?
    var captionErrorMessage: String?

    // Free-canvas arrangement: per-block offsets applied when drag mode is on.
    var isDragEnabled = false
    var blockOffsets: [UUID: CGSize] = [:]

    // MARK: Page appearance
    private static let backgroundKey   = "OneDay.pageBackground"
    private static let borderWidthKey  = "OneDay.borderWidth"
    private static let borderStyleKey  = "OneDay.borderStyle"
    private static let photoShadowKey  = "OneDay.photoShadow"
    private static let enabledTemplatesKey = "OneDay.enabledTemplates"
    private static let photoLayoutModeKey = "OneDay.photoLayoutMode"
    private static let gridColumnCountKey = "OneDay.gridColumnCount"
    private static let gridHorizontalSpacingKey = "OneDay.gridHorizontalSpacing"
    private static let gridVerticalSpacingKey = "OneDay.gridVerticalSpacing"
    private static let gridLazyEnabledKey = "OneDay.gridLazyEnabled"
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
    private static let coverDateFontKey  = CoverDateFont.storageKey
    private static let sectionTintKey    = "OneDay.sectionTint"
    private static let locationBarKey    = "OneDay.locationBar"
    private static let coverModeKey      = "OneDay.coverMode"
    private static let sectionTitleSizeKey = "OneDay.sectionTitleSize"
private static let photoMapKey       = "OneDay.photoMap"
    private static let photoCaptionsKey  = "OneDay.photoCaptions"
private static let albumTagBarKey    = "OneDay.albumTagBar"
    private static let disabledAlbumIDsKey = "OneDay.disabledAlbumIDs"
    private static let albumTagOrderKey  = "OneDay.albumTagOrder"

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
            if borderStyle == .colored { Task { await computeFrameColors(for: Array(allItems.prefix(40))) } }
        }
    }
    var photoShadow: PhotoShadowLevel {
        didSet {
            UserDefaults.standard.set(photoShadow.rawValue, forKey: Self.photoShadowKey)
        }
    }
    var enabledTemplates: Set<BlockTemplate> {
        didSet {
            let raw = enabledTemplates.map(\.rawValue).joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: Self.enabledTemplatesKey)
            recompose()
        }
    }
    var photoLayoutMode: PhotoLayoutMode {
        didSet {
            UserDefaults.standard.set(photoLayoutMode.rawValue, forKey: Self.photoLayoutModeKey)
        }
    }
    var gridColumnCount: Int {
        didSet { }  // 不持久化，每次根据照片数自动选择默认列数
    }
    /// Nil keeps the column-aware 16 / 14 / 12 pt automatic spacing.
    var gridHorizontalSpacing: CGFloat? {
        didSet {
            if let gridHorizontalSpacing {
                UserDefaults.standard.set(Double(gridHorizontalSpacing),
                                          forKey: Self.gridHorizontalSpacingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.gridHorizontalSpacingKey)
            }
        }
    }
    var gridVerticalSpacing: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(gridVerticalSpacing),
                                      forKey: Self.gridVerticalSpacingKey)
        }
    }
    /// When true, the aligned grid uses LazyVGrid (original behavior).
    /// When false, uses a non-lazy VStack+HStack grid (fixes scroll jumping).
    var gridLazyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gridLazyEnabled, forKey: Self.gridLazyEnabledKey)
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
    /// Whether the trajectory map banner appears at the top of the photo page.
    var showPhotoMap: Bool {
        didSet { UserDefaults.standard.set(showPhotoMap, forKey: Self.photoMapKey) }
    }
    var coverMode: CoverMode {
        didSet { UserDefaults.standard.set(coverMode.rawValue, forKey: Self.coverModeKey) }
    }
    var sectionTitleSize: SectionTitleSize {
        didSet { UserDefaults.standard.set(sectionTitleSize.rawValue, forKey: Self.sectionTitleSizeKey) }
    }
    /// Whether to show each photo's caption/description beneath it in the photo
    /// page and in the photo preview.
    var showPhotoCaptions: Bool {
        didSet { UserDefaults.standard.set(showPhotoCaptions, forKey: Self.photoCaptionsKey) }
    }
    /// Whether the album quick-tag bar is shown at the bottom of photo preview.
    var showAlbumTagBar: Bool {
        didSet { UserDefaults.standard.set(showAlbumTagBar, forKey: Self.albumTagBarKey) }
    }
    /// Album localIdentifiers the user has turned off in the preview tag bar.
    /// New albums are enabled by default (not present in this set).
    var disabledAlbumIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(disabledAlbumIDs), forKey: Self.disabledAlbumIDsKey)
        }
    }
    /// Preferred display order of album tags (album localIdentifiers).
    /// Albums not listed appear after, in title order.
    var albumTagOrder: [String] {
        didSet { UserDefaults.standard.set(albumTagOrder, forKey: Self.albumTagOrderKey) }
    }
    // MARK: Cover / back cover state
    private(set) var coverPhotos: [PhotoItem] = []
    private(set) var scatteredCoverPhotos: [ScatteredCoverPhoto] = []
    /// Spread factor used for scattered cover layout (from tunnel settings or default).
    var scatteredSpreadFactor: Double = 1.10
    /// Initial drift offset captured from the tunnel at landing, animated to zero on the cover.
    var scatteredInitialDrift: CGSize = .zero
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
        self.hiddenIDs = Set(items.filter { $0.isHidden }.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Self.backgroundKey)
        self.background = PageBackground(rawValue: saved ?? "") ?? .paper
        let savedWidth = UserDefaults.standard.string(forKey: Self.borderWidthKey)
        self.borderWidth = PhotoBorderWidth(rawValue: savedWidth ?? "") ?? .max
        let savedStyle = UserDefaults.standard.string(forKey: Self.borderStyleKey)
        self.borderStyle = PhotoBorderStyle(rawValue: savedStyle ?? "") ?? .white
        let savedShadow = UserDefaults.standard.string(forKey: Self.photoShadowKey)
        self.photoShadow = PhotoShadowLevel(rawValue: savedShadow ?? "") ?? .max
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
        self.showPhotoMap = UserDefaults.standard.object(forKey: Self.photoMapKey) as? Bool ?? true
        self.coverMode = CoverMode(rawValue: UserDefaults.standard.string(forKey: Self.coverModeKey) ?? "") ?? .collage
        self.sectionTitleSize = SectionTitleSize(rawValue: UserDefaults.standard.string(forKey: Self.sectionTitleSizeKey) ?? "") ?? .xlarge
self.showPhotoCaptions = UserDefaults.standard.object(forKey: Self.photoCaptionsKey) as? Bool ?? false
self.showAlbumTagBar = UserDefaults.standard.object(forKey: Self.albumTagBarKey) as? Bool ?? true
        let savedDisabled = UserDefaults.standard.stringArray(forKey: Self.disabledAlbumIDsKey) ?? []
        self.disabledAlbumIDs = Set(savedDisabled)
        self.albumTagOrder = UserDefaults.standard.stringArray(forKey: Self.albumTagOrderKey) ?? []
        self.photoLayoutMode = PhotoLayoutMode(
            rawValue: UserDefaults.standard.string(forKey: Self.photoLayoutModeKey) ?? ""
        ) ?? .magazine
        let total = items.count
        let defaultColumns = total < 20 ? 1 : total <= 50 ? 2 : 3
        self.gridColumnCount = (1...6).contains(defaultColumns) ? defaultColumns : 3
        if UserDefaults.standard.object(forKey: Self.gridHorizontalSpacingKey) != nil {
            self.gridHorizontalSpacing = CGFloat(
                UserDefaults.standard.double(forKey: Self.gridHorizontalSpacingKey)
            )
        } else {
            self.gridHorizontalSpacing = nil
        }
        if UserDefaults.standard.object(forKey: Self.gridVerticalSpacingKey) != nil {
            self.gridVerticalSpacing = CGFloat(
                UserDefaults.standard.double(forKey: Self.gridVerticalSpacingKey)
            )
        } else {
            self.gridVerticalSpacing = 24
        }
        self.gridLazyEnabled = UserDefaults.standard.object(forKey: Self.gridLazyEnabledKey) as? Bool ?? false
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
        c.shadowLevel    = photoShadow
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
        if borderStyle == .colored { await computeFrameColors(for: Array(allItems.prefix(40))) }
        await computeCoverPhotos()
        await computeCoverBackgroundColor()
        await computePersonStickers()
        if scatteredCoverPhotos.isEmpty { computeScatteredCoverPhotos() }
        await loadPhotoCaptions()
    }

    /// Updates the caption for a single photo in `allItems` and `sections`.
    func updateCaption(_ caption: String?, for item: PhotoItem) async {
        do {
            try await PhotoCaptionManager.shared.setCaption(caption, for: item.asset)
        } catch {
            captionErrorMessage = error.localizedDescription
            return
        }

        let id = item.id
        if let index = allItems.firstIndex(where: { $0.id == id }) {
            allItems[index].caption = caption
        }
        for sIndex in sections.indices {
            for bIndex in sections[sIndex].blocks.indices {
                for iIndex in sections[sIndex].blocks[bIndex].items.indices {
                    if sections[sIndex].blocks[bIndex].items[iIndex].id == id {
                        sections[sIndex].blocks[bIndex].items[iIndex].caption = caption
                    }
                }
            }
        }
    }

    /// Loads captions for all photos asynchronously and updates `allItems`.
    private func loadPhotoCaptions() async {
        guard !allItems.isEmpty else { return }

        let pairs = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, item) in allItems.enumerated() {
                group.addTask {
                    let caption = await PhotoCaptionManager.shared.caption(for: item.asset)
                    return (index, caption)
                }
            }
            var results: [(Int, String?)] = []
            for await result in group { results.append(result) }
            return results
        }

        var updated = allItems
        for (index, caption) in pairs { updated[index].caption = caption }
        allItems = updated

        // Propagate captions into the composed sections so every rendered copy
        // of a PhotoItem has the caption.
        for sIndex in sections.indices {
            for bIndex in sections[sIndex].blocks.indices {
                for iIndex in sections[sIndex].blocks[bIndex].items.indices {
                    let id = sections[sIndex].blocks[bIndex].items[iIndex].id
                    if let caption = updated.first(where: { $0.id == id })?.caption {
                        sections[sIndex].blocks[bIndex].items[iIndex].caption = caption
                    }
                }
            }
        }
    }

    /// Extracts a vivid-but-soft tint color from each photo’s thumbnail for use as a frame.
    func prepareFrameColors(for items: [PhotoItem]) async {
        guard borderStyle == .colored else { return }
        await computeFrameColors(for: items)
    }

    private func computeFrameColors(for items: [PhotoItem]) async {
        let photos = items.filter { !$0.isVideo }
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

    // MARK: Scattered cover photos

    /// Sets scattered cover photos from the tunnel layer that landed on this day.
    /// Matches tunnel photos to this day's PhotoItems by asset identifier.
    func setTunnelCoverPhotos(from layer: TunnelLayer, drift: CGSize = .zero) {
        let itemByID = Dictionary(allItems.map { ($0.asset.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [ScatteredCoverPhoto] = []
        for tp in layer.photos {
            guard let item = itemByID[tp.assetIdentifier] else { continue }
            result.append(ScatteredCoverPhoto(
                id: item.id,
                item: item,
                angle: tp.angle,
                radius: tp.radius,
                baseSize: tp.size))
        }
        if !result.isEmpty {
            scatteredCoverPhotos = result
            scatteredInitialDrift = drift
            let spreadRaw = UserDefaults.standard.string(forKey: "OneDay.tunnelSpread") ?? ""
            scatteredSpreadFactor = (TunnelSpread(rawValue: spreadRaw) ?? .medium).factor
        }
    }

    /// Generates scattered cover photos for non-tunnel days: picks 3-5 random
    /// photos and assigns tube-wall-like coordinates.
    private func computeScatteredCoverPhotos() {
        let photos = allItems.filter { !$0.isVideo }
        guard !photos.isEmpty else { scatteredCoverPhotos = []; return }
        let count = min(photos.count, Int.random(in: 3...5))
        let chosen = photos.shuffled().prefix(count)
        let dayPhase = Double.random(in: 0..<(2 * .pi))
        var result: [ScatteredCoverPhoto] = []
        for (j, item) in chosen.enumerated() {
            let aspect = item.aspectRatio
            let longSide = CGFloat.random(in: 138...162)
            let size: CGSize = aspect >= 1
                ? CGSize(width: longSide, height: longSide / aspect)
                : CGSize(width: longSide * aspect, height: longSide)
            let baseAngle = (2 * .pi / Double(max(count, 1))) * Double(j)
            let angle = dayPhase + baseAngle + Double.random(in: -0.4...0.4)
            result.append(ScatteredCoverPhoto(
                id: item.id,
                item: item,
                angle: angle,
                radius: Double.random(in: 0.55...1.3),
                baseSize: size))
        }
        scatteredCoverPhotos = result
        scatteredSpreadFactor = 1.50
    }

    /// True when at least one located photo/video exists (map is worth showing).
    var hasAnyLocation: Bool { !routeLocations.isEmpty }

    /// Centroid coordinate of each route stop (one dot per stop on the map).
    var routeStopCoordinates: [CLLocationCoordinate2D] {
        routeSegments.map(\.coordinate)
    }

    /// Whether the trajectory map banner should appear at the top of the photo
    /// page: requires the user setting on and at least one located photo.
    var showsPhotoMap: Bool { showPhotoMap && hasAnyLocation }

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

    /// A chronological route stop: a geographic cluster of located items. Built
    /// purely from coordinates so it stays consistent with the map and is not
    /// affected by time-band sectioning. Revisits appear as separate stops.
    typealias RouteSegment = PhotoRouteSegment

    private var segmentNames: [String: String] = [:]

    /// Real trajectory: every located photo/video in chronological order.
    var routeLocations: [CLLocation] {
        allItems.compactMap(\.location)
    }

    /// Geographic clustering of located items into ordered stops (route mode:
    /// a returning location yields a new stop). A new stop starts when an item
    /// is farther than 200m from the running centroid of the
    /// current stop.
    var routeSegments: [RouteSegment] {
        PhotoRoute.segments(for: allItems)
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

    /// The block that contains a given photo id, used to silently scroll the
    /// day page so the preview's current photo cell is on screen for the hero
    /// fly-back to land in its real slot.
    func blockID(forItemID id: String) -> UUID? {
        for section in sections {
            for block in section.blocks where block.items.contains(where: { $0.id == id }) {
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

    func isHidden(_ item: PhotoItem) -> Bool {
        hiddenIDs.contains(item.id) || item.isHidden
    }

    @discardableResult
    func setHidden(_ hidden: Bool, item: PhotoItem) async -> Bool {
        do {
            try await PhotoActionService.shared.setHidden(hidden, on: item.asset)
            if hidden {
                hiddenIDs.insert(item.id)
                remove(item)
            } else {
                hiddenIDs.remove(item.id)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Albums

    func userAlbums() -> [AlbumInfo] {
        orderedAlbums(PhotoActionService.shared.userAlbums())
    }

    /// User albums that should appear in the preview tag bar.
    func enabledAlbums() -> [AlbumInfo] {
        userAlbums().filter { !disabledAlbumIDs.contains($0.id) }
    }

    private func orderedAlbums(_ albums: [AlbumInfo]) -> [AlbumInfo] {
        let byID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        var result: [AlbumInfo] = []
        var seen = Set<String>()
        for id in albumTagOrder {
            if let album = byID[id] {
                result.append(album)
                seen.insert(id)
            }
        }
        for album in albums where !seen.contains(album.id) {
            result.append(album)
        }
        return result
    }

    @discardableResult
    func addToAlbum(_ album: AlbumInfo, item: PhotoItem) async -> Bool {
        do {
            try await PhotoActionService.shared.addToAlbum(identifier: album.id, assets: [item.asset])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func removeFromAlbum(_ album: AlbumInfo, item: PhotoItem) async -> Bool {
        do {
            try await PhotoActionService.shared.removeFromAlbum(identifier: album.id, assets: [item.asset])
            return true
        } catch {
            return false
        }
    }

    /// Which of the given albums currently contain this photo.
    func albumIDs(containing item: PhotoItem, among albums: [AlbumInfo]) -> Set<String> {
        PhotoActionService.shared.albumIDs(
            containing: item.asset,
            among: albums.map(\.id)
        )
    }

    func createAlbum(named name: String, item: PhotoItem) async {
        try? await PhotoActionService.shared.addToAlbum(named: name, assets: [item.asset])
    }

    /// Creates an empty album for configuration; does not add a photo.
    @discardableResult
    func createEmptyAlbum(named name: String) async -> AlbumInfo? {
        try? await PhotoActionService.shared.createAlbum(named: name)
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

    func removeItems(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let toRemove = allItems.filter { ids.contains($0.id) }
        for item in toRemove {
            remove(item)
        }
    }

    private func remove(_ item: PhotoItem) {
        allItems.removeAll { $0.id == item.id }
        favoriteIDs.remove(item.id)
        hiddenIDs.remove(item.id)
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
