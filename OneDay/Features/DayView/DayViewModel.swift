import SwiftUI
import Photos
import CoreLocation

enum CoverMode: String, CaseIterable {
    case collage
    case scattered
    case minimal

    var label: String {
        switch self {
        case .collage:   return "拼贴"
        case .scattered: return "散布"
        case .minimal:   return "简约"
        }
    }
}

enum CoverBackgroundMode: String, CaseIterable, Identifiable {
    case vibrant
    case bright

    var id: String { rawValue }
    var label: String {
        switch self {
        case .vibrant: return "主色·艳丽"
        case .bright:  return "明快"
        }
    }
}

enum SectionTitleSize: String, CaseIterable, Identifiable {
    case xsmall, small, medium, large, xlarge
    var id: String { rawValue }
    var label: String { ["最小", "较小", "适中", "较大", "最大"][Self.allCases.firstIndex(of: self) ?? 4] }
    /// Largest is now the previous "small", "large" is the previous "xsmall",
    /// and the remaining sizes decrease in 6pt steps.
    var size: CGFloat { [14, 20, 26, 32, 38][Self.allCases.firstIndex(of: self) ?? 4] }
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
    var selected: PhotoItem? {
        didSet {
            guard selected == nil,
                  pendingClassificationRefresh || pendingSourceItems != nil else { return }
            // Let the hero flight finish restoring its source cell first.
            Task { [weak self] in
                guard let self, self.selected == nil else { return }
                if let items = self.pendingSourceItems {
                    self.pendingSourceItems = nil
                    self.replaceSourceItems(items)
                }
                if self.pendingClassificationRefresh { self.refreshMediaClassifications() }
            }
        }
    }
    /// The photo currently being viewed inside the preview. Drives the hero
    /// fly-back so closing returns to the photo on screen now (requirement B).
    var previewCurrentID: String?
    private(set) var clockwiseRotationVersions: [String: String] = [:]

    /// A content edit cannot wait for preview dismissal: both the card and its
    /// landing cell need the new aspect before a close flight can start.
    func refreshEditedAsset(_ asset: PHAsset, clockwiseRotation: Bool = false) {
        let id = asset.localIdentifier
        guard let previous = allItemsUnfiltered.first(where: { $0.id == id }) else { return }
        var replacement = PhotoItem(asset: asset, sharedSource: previous.sharedSource,
                                    isOwnSharedContribution: previous.isOwnSharedContribution)
        replacement.caption = previous.caption
        replacement.captureTimeZone = previous.captureTimeZone
        guard replacement.contentVersion != previous.contentVersion else { return }
        if clockwiseRotation { clockwiseRotationVersions[id] = replacement.contentVersion }
        func replacing(_ items: [PhotoItem]) -> [PhotoItem] {
            items.map { $0.id == id ? replacement : $0 }
        }
        allItemsUnfiltered = replacing(allItemsUnfiltered)
        allItems = replacing(allItems)
        if let pendingSourceItems { self.pendingSourceItems = replacing(pendingSourceItems) }
        if selected?.id == id { selected = replacement }
        coverPhotos = replacing(coverPhotos)
        scatteredCoverPhotos = scatteredCoverPhotos.map {
            ScatteredCoverPhoto(id: $0.id, item: $0.item.id == id ? replacement : $0.item,
                                angle: $0.angle, radius: $0.radius, baseSize: $0.baseSize)
        }
        if tunnelCoverPhoto?.id == id { tunnelCoverPhoto = replacement }
        sourceRevision = UUID()
        rebuildSections(animated: false)
    }

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
    private static let photoCornerRadiusKey = "OneDay.photoCornerRadius"
    private static let enabledTemplatesKey = "OneDay.enabledTemplates"
    private static let photoLayoutModeKey = "OneDay.photoLayoutMode"
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
    private static let bottomToolbarKey  = "OneDay.bottomToolbar"
    private static let scrubberMarksKey  = "OneDay.scrubberSectionMarks"
    private static let scrubberTickHapticsKey = "OneDay.scrubberTickHaptics"
    private static let dayScrollIndicatorKey = "OneDay.dayScrollIndicator"
    private static let textDayNavKey     = "OneDay.textDayNavigation"
    private static let coverModeKey      = "OneDay.coverMode"
    private static let coverBackgroundModeKey = "OneDay.coverBackgroundMode"
    private static let sectionTitleSizeKey = "OneDay.sectionTitleSize"
    private static let mapBlendModeKey     = "OneDay.mapBlendMode"
private static let photoMapKey       = "OneDay.photoMap"
    private static let photoCaptionsKey  = "OneDay.photoCaptions"
private static let albumTagBarKey    = "OneDay.albumTagBar"
    private static let disabledAlbumIDsKey = "OneDay.disabledAlbumIDs"
    private static let albumTagOrderKey  = "OneDay.albumTagOrder"
    private static let includeSharedAlbumsKey = "OneDay.includeSharedAlbums"
    static let sharedContributorMatchKey = PhotoLibraryService.sharedContributorMatchKey

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
            if borderStyle == .colored {
                Task {
                    await computeFrameColors(
                        for: Array(allItems.prefix(40)) + coverPhotos + scatteredCoverPhotos.map(\.item))
                }
            }
        }
    }
    var photoShadow: PhotoShadowLevel {
        didSet {
            UserDefaults.standard.set(photoShadow.rawValue, forKey: Self.photoShadowKey)
        }
    }
    var photoCornerRadius: PhotoCornerRadius {
        didSet {
            UserDefaults.standard.set(photoCornerRadius.rawValue, forKey: Self.photoCornerRadiusKey)
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
    private var gridColumnPolicy: GridColumnPolicy {
        didSet { gridColumnPolicy.save() }
    }
    var gridColumnMode: GridColumnPolicy.Mode {
        get { gridColumnPolicy.mode }
        set { gridColumnPolicy.mode = newValue }
    }
    var manualGridColumnCount: Int { gridColumnPolicy.manualCount }
    var gridColumnCount: Int {
        get { gridColumnPolicy.columnCount }
        set { gridColumnPolicy.selectManual(newValue) }
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
    /// Whether the bottom quick-scroll toolbar is shown on the photo page.
    var showBottomToolbar: Bool {
        didSet { UserDefaults.standard.set(showBottomToolbar, forKey: Self.bottomToolbarKey) }
    }
    /// Whether the scrubber draws (and buzzes on) section-start marks.
    var showScrubberSectionMarks: Bool {
        didSet { UserDefaults.standard.set(showScrubberSectionMarks, forKey: Self.scrubberMarksKey) }
    }
    /// Whether scrubbing across ordinary ticks gives a light haptic tick.
    var scrubberTickHaptics: Bool {
        didSet { UserDefaults.standard.set(scrubberTickHaptics, forKey: Self.scrubberTickHapticsKey) }
    }
    /// Whether the photo page shows the system scroll indicator.
    var showDayScrollIndicator: Bool {
        didSet { UserDefaults.standard.set(showDayScrollIndicator, forKey: Self.dayScrollIndicatorKey) }
    }
    /// Whether the text previous/next links appear at the end of the photo page.
    var showTextDayNavigation: Bool {
        didSet { UserDefaults.standard.set(showTextDayNavigation, forKey: Self.textDayNavKey) }
    }
    /// Whether the trajectory map banner appears at the top of the photo page.
    var showPhotoMap: Bool {
        didSet { UserDefaults.standard.set(showPhotoMap, forKey: Self.photoMapKey) }
    }
    var coverMode: CoverMode {
        didSet { UserDefaults.standard.set(coverMode.rawValue, forKey: Self.coverModeKey) }
    }
    var coverBackgroundMode: CoverBackgroundMode {
        didSet {
            UserDefaults.standard.set(coverBackgroundMode.rawValue, forKey: Self.coverBackgroundModeKey)
            Task { await computeCoverBackgroundColor(generation: editorialPreparationID) }
        }
    }
    var sectionTitleSize: SectionTitleSize {
        didSet { UserDefaults.standard.set(sectionTitleSize.rawValue, forKey: Self.sectionTitleSizeKey) }
    }
    private var titleSegmentation: TitleSegmentationPolicy {
        didSet {
            titleSegmentation.save()
            rebuildSections()
        }
    }
    var titlePlaceSegmentation: Bool {
        get { titleSegmentation.placeEnabled }
        set { titleSegmentation.placeEnabled = newValue }
    }
    var titleNestedTimeSegmentation: Bool {
        get { titleSegmentation.nestedTimeEnabled }
        set { titleSegmentation.nestedTimeEnabled = newValue }
    }
    var titleTimeSegmentation: Bool {
        get { titleSegmentation.timeEnabled }
        set { titleSegmentation.timeEnabled = newValue }
    }
    /// How the grayscale trajectory map blends into the page background.
    var mapBlendMode: MapBlendMode {
        didSet { UserDefaults.standard.set(mapBlendMode.rawValue, forKey: Self.mapBlendModeKey) }
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
    /// When `true`, photos contributed by other members of the user's iCloud
    /// Shared Photo Library are included in the day view. Default is `true`
    /// (on by first-run). Only the body and its captions/places are re-filtered.
    var includeSharedAlbums: Bool = false {
        didSet {
            UserDefaults.standard.set(includeSharedAlbums, forKey: Self.includeSharedAlbumsKey)
            applySharedFilter(animated: true)
            scheduleReprepareAfterFilterChange()
        }
    }
    /// Test toggle: when `true`, shared-album photos the user contributed
    /// themselves (matched to the own library by capture timestamp) are hidden
    /// so only photos shared by others remain and get the shared badge. When
    /// `false`, every shared-album photo is shown and badged. Default `true`.
    var sharedContributorMatch: Bool = true {
        didSet {
            UserDefaults.standard.set(sharedContributorMatch, forKey: Self.sharedContributorMatchKey)
            applySharedFilter(animated: true)
            scheduleReprepareAfterFilterChange()
        }
    }
    private var mediaTabs: DayMediaTabs<PhotoItem>
    private(set) var selectedMediaCategory: MediaCategory?
    var availableMediaCategories: [MediaCategory] { mediaTabs.availableCategories }
    var showsMediaTabs: Bool { mediaTabs.showsTabBar }

    /// Complete source, independent from both tunnel toggles and the active Tab.
    private var allItemsUnfiltered: [PhotoItem] = []
    private(set) var sourceRevision = UUID()
    private var filterPreparationID = UUID()
    private var bodyPreparationTask: Task<Void, Never>?
    private var dayClassificationTask: Task<Void, Never>?
    private var pendingClassificationRefresh = false
    private var pendingSourceItems: [PhotoItem]?
    private var editorialPreparationID = UUID()
    private var editorialPreparationTask: Task<Void, Never>?

    /// Fixed default source policy: own originals and other people's shared
    /// media, without duplicate own shared contributions or display filters.
    private var editorialItems: [PhotoItem] {
        DayMediaScope.editorialItems(
            from: allItemsUnfiltered,
            mediaType: { $0.asset.mediaType },
            isOwnSharedContribution: { $0.isOwnSharedContribution })
    }

    // MARK: Cover / back cover state
    private(set) var coverPhotos: [PhotoItem] = []
    private(set) var scatteredCoverPhotos: [ScatteredCoverPhoto] = []
    private(set) var tunnelCoverPhoto: PhotoItem?
    /// Spread factor used for scattered cover layout (from tunnel settings or default).
    var scatteredSpreadFactor: Double = 1.10
    /// Initial drift offset captured from the tunnel at landing, animated to zero on the cover.
    var scatteredInitialDrift: CGSize = .zero
    private(set) var personStickers: [PersonSticker] = []
    private(set) var coverBackgroundColor: Color = Color(white: 0.96)
    private var coverBackgroundIsDark = false
    private(set) var backCoverBackgroundColor: Color = Color(white: 0.12)
    private var backCoverIsDark = true
    private(set) var coverPlaces: [String] = []

    var coverPhotoCount: Int { editorialItems.filter { !$0.isVideo }.count }
    var coverVideoCount: Int { editorialItems.filter(\.isVideo).count }
    var coverRouteLocations: [CLLocation] { editorialItems.compactMap(\.location) }
    var hasCoverLocation: Bool { !coverRouteLocations.isEmpty }
    var coverTravelKilometers: Double { routeDistanceKilometers(for: coverRouteLocations) }

    var minimalCoverPhoto: PhotoItem? {
        tunnelCoverPhoto ?? coverPhotos.first
    }

    var coverColorScheme: ColorScheme {
        coverBackgroundIsDark ? .dark : .light
    }
    var backCoverColorScheme: ColorScheme {
        backCoverIsDark ? .dark : .light
    }

    /// Editorial summary for the back cover.
    var backCoverSummary: BackCoverSummary {
        BackCoverSummary(
            photoCount: coverPhotoCount,
            videoCount: coverVideoCount,
            kilometers: coverTravelKilometers,
            places: coverPlaces
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
        case .pureWhite: return Color(white: 1.0)
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
        let sortedItems = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
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
        let savedCornerRadius = UserDefaults.standard.string(forKey: Self.photoCornerRadiusKey)
        self.photoCornerRadius = PhotoCornerRadius(rawValue: savedCornerRadius ?? "") ?? .none
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
        self.showBottomToolbar = UserDefaults.standard.object(forKey: Self.bottomToolbarKey) as? Bool ?? true
        self.showScrubberSectionMarks = UserDefaults.standard.object(forKey: Self.scrubberMarksKey) as? Bool ?? true
        self.scrubberTickHaptics = UserDefaults.standard.object(forKey: Self.scrubberTickHapticsKey) as? Bool ?? true
        self.showDayScrollIndicator = UserDefaults.standard.object(forKey: Self.dayScrollIndicatorKey) as? Bool ?? true
        self.showTextDayNavigation = UserDefaults.standard.object(forKey: Self.textDayNavKey) as? Bool ?? false
        self.showPhotoMap = UserDefaults.standard.object(forKey: Self.photoMapKey) as? Bool ?? true
        self.coverMode = CoverMode(rawValue: UserDefaults.standard.string(forKey: Self.coverModeKey) ?? "") ?? .collage
        self.coverBackgroundMode = CoverBackgroundMode(
            rawValue: UserDefaults.standard.string(forKey: Self.coverBackgroundModeKey) ?? ""
        ) ?? .vibrant
        self.sectionTitleSize = SectionTitleSize(rawValue: UserDefaults.standard.string(forKey: Self.sectionTitleSizeKey) ?? "") ?? .xlarge
        self.mapBlendMode = MapBlendMode(rawValue: UserDefaults.standard.string(forKey: Self.mapBlendModeKey) ?? "") ?? .multiply
self.showPhotoCaptions = UserDefaults.standard.object(forKey: Self.photoCaptionsKey) as? Bool ?? false
self.showAlbumTagBar = UserDefaults.standard.object(forKey: Self.albumTagBarKey) as? Bool ?? true
        let savedDisabled = UserDefaults.standard.stringArray(forKey: Self.disabledAlbumIDsKey) ?? []
        self.disabledAlbumIDs = Set(savedDisabled)
        self.albumTagOrder = UserDefaults.standard.stringArray(forKey: Self.albumTagOrderKey) ?? []
        self.photoLayoutMode = PhotoLayoutMode(
            rawValue: UserDefaults.standard.string(forKey: Self.photoLayoutModeKey) ?? ""
        ) ?? .magazine
        self.gridColumnPolicy = GridColumnPolicy(itemCount: items.count)
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
        // Compute the first-run preference and the section composition using only
        // local values; all `self.* = ...` writes are deferred to the very end
        // of init so phase-2 reads of `self` are never required mid-init.
        let savedShared = UserDefaults.standard.object(forKey: Self.includeSharedAlbumsKey) as? Bool ?? true
        let savedMatch = UserDefaults.standard.object(forKey: Self.sharedContributorMatchKey) as? Bool ?? true
        let sharedItems = Self.filterShared(
            sortedItems, includeShared: savedShared, contributorMatch: savedMatch)
        let tabs = DayMediaTabs(items: sharedItems) { MediaFilter.category(for: $0.asset) }
        let selectedCategory = tabs.selection(preserving: nil)
        let composedItems = tabs.items(in: selectedCategory)
        let segmentation = TitleSegmentationPolicy()
        let composedSections = MagazineLayoutEngine.compose(
            composedItems, enabled: tplSet, policy: segmentation)
        self.titleSegmentation = segmentation
        self.allItemsUnfiltered = sortedItems
        self.allItems = composedItems
        self.includeSharedAlbums = savedShared
        self.sharedContributorMatch = savedMatch
        self.mediaTabs = tabs
        self.selectedMediaCategory = selectedCategory
        self.sections = composedSections
        // Old multi-select choices no longer control the day body.
        UserDefaults.standard.removeObject(forKey: "OneDay.dayMediaCategories")
    }

    var photoCount: Int { allItems.filter { !$0.isVideo }.count }
    var videoCount: Int { allItems.filter(\.isVideo).count }
    var layoutConfig: LayoutConfig {
        var c = LayoutConfig.make(itemCount: allItems.count)
        c.borderScale    = borderWidth.scale
        c.borderStyle    = borderStyle
        c.shadowLevel    = photoShadow
        c.staggerFactor  = scrollStagger.factor
        c.cornerRadius   = photoCornerRadius.value
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
    /// so nothing is dropped. A stop whose title has not resolved yet passes no
    /// name so its heading reserves space instead of a stale placeholder.
    private func placeGroups() -> [(id: String, name: String?, items: [PhotoItem])] {
        let stops = routeStops
        guard !stops.isEmpty else { return [] }
        let names = routeStopDisplayNames
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
        return zip(stops, groups).enumerated().map { offset, pair in
            (id: pair.0.id,
             name: pair.0.nameState == .loading ? nil : names[offset],
             items: pair.1)
        }
    }

    /// Rebuilds the body using the saved place/time segmentation choices.
    private func rebuildSections(animated: Bool = true) {
        let similar: ((PhotoItem, PhotoItem) -> Bool)? =
            visionDistances.isEmpty ? nil : { [weak self] a, b in
                self?.visionSimilar(a, b) ?? false
            }
        let newSections = MagazineLayoutEngine.compose(
            allItems, similar: similar, enabled: enabledTemplates,
            policy: titleSegmentation, places: placeGroups())
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

    // MARK: Shared-library filter

    /// Re-derives `allItems` from `allItemsUnfiltered` according to the current
    /// `includeSharedAlbums` toggle, and rebuilds sections synchronously so the
    /// new body set is visible immediately. Cover/history state is not touched.
    /// Applies the two shared-photo filters to `items`:
    /// - `includeShared == false` removes every shared-album photo.
    /// - otherwise, `contributorMatch == true` removes the user's own
    ///   contributions (so only photos shared by others remain).
    static func filterShared(
        _ items: [PhotoItem],
        includeShared: Bool,
        contributorMatch: Bool
    ) -> [PhotoItem] {
        if !includeShared {
            return items.filter { !$0.isFromSharedLibrary }
        }
        if contributorMatch {
            return items.filter { !$0.isOwnSharedContribution }
        }
        return items
    }

    func selectMediaCategory(_ category: MediaCategory) {
        guard selected == nil, category != selectedMediaCategory,
              availableMediaCategories.contains(category) else { return }
        selectedMediaCategory = category
        applySharedFilter(animated: false)
        scheduleReprepareAfterFilterChange()
    }

    func refreshMediaClassifications() {
        guard selected == nil else {
            pendingClassificationRefresh = true
            return
        }
        pendingClassificationRefresh = false
        let previousIDs = allItems.map(\.id)
        applySharedFilter(animated: true)
        if allItems.map(\.id) != previousIDs {
            scheduleReprepareAfterFilterChange()
        }
    }

    private func applySharedFilter(animated: Bool, force: Bool = false) {
        guard selected == nil else {
            pendingClassificationRefresh = true
            return
        }
        let sharedItems = Self.filterShared(
            allItemsUnfiltered,
            includeShared: includeSharedAlbums,
            contributorMatch: sharedContributorMatch)
        mediaTabs = DayMediaTabs(items: sharedItems) { MediaFilter.category(for: $0.asset) }
        selectedMediaCategory = mediaTabs.selection(preserving: selectedMediaCategory)
        let filtered = mediaTabs.items(in: selectedMediaCategory)
        guard force || filtered.map(\.id) != allItems.map(\.id) else { return }
        filterPreparationID = UUID()
        bodyPreparationTask?.cancel()
        if filtered.isEmpty {
            warmColor = Color(red: 0.93, green: 0.78, blue: 0.62)
            dominantColor = Color(white: 0.5)
            vibrantColor = Color(white: 0.5)
            brightColor = Color(white: 0.95)
            bright2Color = Color(white: 1.0)
            dominantIsDark = false
            vibrantIsDark = false
        }
        visionDistances = [:]
        blockOffsets = [:]
        allItems = filtered
        rebuildSections(animated: animated)
    }

    private func isCurrentFilterPreparation(_ generation: UUID?) -> Bool {
        !Task.isCancelled && (generation == nil || filterPreparationID == generation)
    }

    private func scheduleReprepareAfterFilterChange() {
        guard selected == nil else {
            pendingClassificationRefresh = true
            return
        }
        bodyPreparationTask?.cancel()
        let generation = UUID()
        filterPreparationID = generation
        bodyPreparationTask = Task {
            await reprepareAfterFilterChange(generation: generation)
        }
    }

    /// Refreshes only body-derived colors, grouping, places, and captions.
    fileprivate func reprepareAfterFilterChange(generation: UUID) async {
        await computeWarmColor(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        await applyVisionGrouping(generation: generation)
        guard filterPreparationID == generation else { return }
        await resolveSegmentPlaces(generation: generation)
        guard filterPreparationID == generation else { return }
        await resolvePlaces(generation: generation)
        guard filterPreparationID == generation else { return }
        if borderStyle == .colored {
            await computeFrameColors(for: Array(allItems.prefix(40)), generation: generation)
        }
        guard filterPreparationID == generation else { return }
        await loadPhotoCaptions(generation: generation)
    }

    // MARK: Preparation (Vision similarity + places + warm color)

    func prepare() async {
        // This task has its own lifetime, so body-filter changes cannot abort it.
        Task { await prepareEditorial() }
        classifyDayImages()
        let generation = filterPreparationID
        guard isCurrentFilterPreparation(generation) else { return }
        await computeWarmColor(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        await applyVisionGrouping(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        rebuildSections()
        await resolveSegmentPlaces(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        await resolvePlaces(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        if borderStyle == .colored {
            await computeFrameColors(for: Array(allItems.prefix(40)), generation: generation)
        }
        guard isCurrentFilterPreparation(generation) else { return }
        await loadPhotoCaptions(generation: generation)
    }

    private func classifyDayImages() {
        let previous = dayClassificationTask
        previous?.cancel()
        let assets = allItemsUnfiltered.map(\.asset)
        dayClassificationTask = Task {
            // Let a cancelled batch release its in-flight identifiers before
            // asking for the same day's replacement PHAsset snapshots.
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await OtherImageClassificationService.shared.classifyCurrentDay(assets)
        }
    }

    /// Coalesced once per source revision, not once per body-filter revision.
    func prepareEditorial() async {
        if let task = editorialPreparationTask {
            await task.value
            return
        }
        let generation = editorialPreparationID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.prepareEditorialContent(generation: generation)
        }
        editorialPreparationTask = task
        await task.value
    }

    private func isCurrentEditorialPreparation(_ generation: UUID) -> Bool {
        editorialPreparationID == generation && !Task.isCancelled
    }

    private func prepareEditorialContent(generation: UUID) async {
        await computeCoverPhotos(generation: generation)
        guard isCurrentEditorialPreparation(generation) else { return }
        await computeCoverBackgroundColor(generation: generation)
        guard isCurrentEditorialPreparation(generation) else { return }
        if scatteredCoverPhotos.isEmpty { computeScatteredCoverPhotos() }
        await prepareFrameColors(for: coverPhotos + scatteredCoverPhotos.map(\.item))
        guard isCurrentEditorialPreparation(generation) else { return }
        await computePersonStickers(generation: generation)
        guard isCurrentEditorialPreparation(generation) else { return }

        var stopPlaces: [PlaceNaming.StopPlace] = []
        for segment in PhotoRoute.segments(for: editorialItems) {
            let location = CLLocation(
                latitude: segment.coordinate.latitude, longitude: segment.coordinate.longitude)
            let resolution = await LocationResolver.shared.place(for: location, priority: .pageContent)
            guard isCurrentEditorialPreparation(generation) else { return }
            stopPlaces.append(PlaceNaming.StopPlace(resolution))
        }
        var places: [String] = []
        var seen = Set<String>()
        for title in PlaceNaming.stopTitles(for: stopPlaces) {
            guard case .title(let name) = title, seen.insert(name).inserted else { continue }
            places.append(name)
        }
        coverPlaces = places
    }

    /// Real library updates replace the source; preview updates wait until close.
    func replaceSourceItems(_ items: [PhotoItem]) {
        guard selected == nil else {
            pendingSourceItems = items
            return
        }
        var sorted = items.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        let previousByID = Dictionary(allItemsUnfiltered.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        for index in sorted.indices where sorted[index].caption == nil {
            sorted[index].caption = previousByID[sorted[index].id]?.caption
        }
        let unchanged = sorted.count == allItemsUnfiltered.count
            && zip(sorted, allItemsUnfiltered).allSatisfy { pair in
                let (new, old) = pair
                return new.id == old.id
                    && new.asset.modificationDate == old.asset.modificationDate
                    && new.creationDate == old.creationDate
                    && new.isFromSharedLibrary == old.isFromSharedLibrary
                    && new.isOwnSharedContribution == old.isOwnSharedContribution
                    && new.captureTimeZone == old.captureTimeZone
            }
        allItemsUnfiltered = sorted
        favoriteIDs = Set(sorted.filter(\.isFavorite).map(\.id))
        hiddenIDs = Set(sorted.filter(\.isHidden).map(\.id))
        guard !unchanged else { return }
        sourceRevision = UUID()
        invalidateEditorialPreparation()
        applySharedFilter(animated: true, force: true)
        classifyDayImages()
        scheduleReprepareAfterFilterChange()
    }

    private func invalidateEditorialPreparation() {
        editorialPreparationID = UUID()
        editorialPreparationTask?.cancel()
        editorialPreparationTask = nil
        let sourceIDs = Set(editorialItems.map(\.id))
        coverPhotos.removeAll { !sourceIDs.contains($0.id) }
        scatteredCoverPhotos.removeAll { !sourceIDs.contains($0.id) }
        if let tunnelCoverPhoto, !sourceIDs.contains(tunnelCoverPhoto.id) {
            self.tunnelCoverPhoto = nil
        }
        personStickers = []
        coverPlaces = []
        Task { await prepareEditorial() }
    }

    /// Updates the caption for a single photo in `allItems` and `sections`.
    func updateCaption(_ caption: String?, for item: PhotoItem) async {
        guard item.sharedCapabilities.canEditCaption else { return }
        do {
            try await PhotoCaptionManager.shared.setCaption(caption, for: item.asset)
        } catch {
            captionErrorMessage = error.localizedDescription
            return
        }

        let id = item.id
        if let index = allItemsUnfiltered.firstIndex(where: { $0.id == id }) {
            allItemsUnfiltered[index].caption = caption
        }
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
    private func loadPhotoCaptions(generation: UUID? = nil) async {
        let items = allItems
        guard !items.isEmpty else { return }

        let pairs = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let caption = await PhotoCaptionManager.shared.caption(for: item.asset)
                    return (index, caption)
                }
            }
            var results: [(Int, String?)] = []
            for await result in group { results.append(result) }
            return results
        }

        guard isCurrentFilterPreparation(generation) else { return }
        var captionsByID: [String: String] = [:]
        for (index, caption) in pairs where items.indices.contains(index) {
            if let caption { captionsByID[items[index].id] = caption }
        }
        var updated = allItems
        for index in updated.indices {
            if let caption = captionsByID[updated[index].id] {
                updated[index].caption = caption
            }
        }
        allItems = updated
        for index in allItemsUnfiltered.indices {
            if let caption = captionsByID[allItemsUnfiltered[index].id] {
                allItemsUnfiltered[index].caption = caption
            }
        }

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

    private func computeFrameColors(
        for items: [PhotoItem],
        generation: UUID? = nil
    ) async {
        let photos = items.filter { !$0.isVideo }
        for item in photos where photoFrameColors[item.id] == nil {
            guard isCurrentFilterPreparation(generation) else { return }
            guard let img = await ImageLoader.shared.thumbnail(asset: item.asset,
                                                              size: CGSize(width: 48, height: 48)),
                  let base = img.averageColor else { continue }
            guard isCurrentFilterPreparation(generation) else { return }
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

    private func computeWarmColor(generation: UUID? = nil) async {
        let items = allItems
        guard let first = items.first(where: { !$0.isVideo }) ?? items.first else { return }
        guard let image = await ImageLoader.shared.thumbnail(asset: first.asset,
                                                            size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else { return }
        guard isCurrentFilterPreparation(generation) else { return }
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
    private func computeCoverPhotos(generation: UUID) async {
        guard isCurrentEditorialPreparation(generation) else { return }
        let photos = editorialItems.filter { !$0.isVideo }
        guard !photos.isEmpty else { coverPhotos = []; return }
        if photos.count <= 2 { coverPhotos = photos; return }
        let ranked = await PhotoSharpnessRanker.shared.rank(photos, top: 2)
        guard isCurrentEditorialPreparation(generation) else { return }
        coverPhotos = ranked
    }

    /// Cover and back-cover backgrounds rotate away from the hero photo's hue:
    /// +30° for the cover and +180° for the back. The selected mode controls
    /// whether those hues use the original vivid ranges or the pale `bright2`
    /// saturation/brightness range.
    private func computeCoverBackgroundColor(generation: UUID) async {
        let mode = coverBackgroundMode
        guard let hero = coverPhotos.first ?? editorialItems.first,
              let image = await ImageLoader.shared.thumbnail(
                asset: hero.asset, size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else {
            guard isCurrentEditorialPreparation(generation), mode == coverBackgroundMode else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                switch mode {
                case .vibrant:
                    coverBackgroundColor = Color(red: 0.93, green: 0.78, blue: 0.62)
                    coverBackgroundIsDark = false
                    backCoverBackgroundColor = Color(white: 0.12)
                    backCoverIsDark = true
                case .bright:
                    coverBackgroundColor = Color(white: 1.0)
                    coverBackgroundIsDark = false
                    backCoverBackgroundColor = Color(white: 1.0)
                    backCoverIsDark = false
                }
            }
            return
        }
        guard isCurrentEditorialPreparation(generation), mode == coverBackgroundMode else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        let palette: (cover: Color, coverDark: Bool, back: Color, backDark: Bool)
        switch mode {
        case .vibrant:
            let (cover, coverDark) = rotatedColor(
                baseHue: h, baseSat: s, baseBri: b,
                hueShift: 30.0 / 360.0, satFloor: 0.62, satScale: 2.3,
                briScale: 1.06, briRange: 0.60...0.92)
            let (back, backDark) = rotatedColor(
                baseHue: h, baseSat: s, baseBri: b,
                hueShift: 0.5, satFloor: 0.5, satScale: 2.0,
                briScale: 0.82, briRange: 0.28...0.60)
            palette = (cover, coverDark, back, backDark)
        case .bright:
            let (cover, coverDark) = bright2Tint(
                h: shiftedHue(h, by: 30.0 / 360.0), s: s)
            let (back, backDark) = bright2Tint(
                h: shiftedHue(h, by: 0.5), s: s)
            palette = (cover, coverDark, back, backDark)
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            coverBackgroundColor = palette.cover
            coverBackgroundIsDark = palette.coverDark
            backCoverBackgroundColor = palette.back
            backCoverIsDark = palette.backDark
        }
    }

    private func shiftedHue(_ hue: CGFloat, by shift: CGFloat) -> CGFloat {
        var result = (hue + shift).truncatingRemainder(dividingBy: 1)
        if result < 0 { result += 1 }
        return result
    }

    /// Builds an HSB color with the hue rotated by `hueShift` (0...1 turns) and
    /// saturation/brightness pushed into an editorial range.
    private func rotatedColor(baseHue h: CGFloat, baseSat s: CGFloat, baseBri b: CGFloat,
                              hueShift: CGFloat, satFloor: CGFloat, satScale: CGFloat,
                              briScale: CGFloat, briRange: ClosedRange<CGFloat>) -> (Color, Bool) {
        let hue = shiftedHue(h, by: hueShift)
        let sat = max(min(s * satScale, 0.92), satFloor)
        let bri = min(max(b * briScale, briRange.lowerBound), briRange.upperBound)
        let color = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        return (Color(uiColor: color), bri < 0.5)
    }

    /// Extracts up to 2 distinct person stickers (transparent foreground + white outline).
    private func computePersonStickers(generation: UUID) async {
        guard isCurrentEditorialPreparation(generation) else { return }
        let photos = editorialItems.filter { !$0.isVideo }
        guard !photos.isEmpty else { personStickers = []; return }
        // Scan the cover photos first (most likely to contain the day's people),
        // then the rest chronologically.
        let coverIDs = Set(coverPhotos.map(\.id))
        let ordered = coverPhotos + photos.filter { !coverIDs.contains($0.id) }
        let stickers = await PersonStickerExtractor.shared.extract(from: ordered, max: 2)
        guard isCurrentEditorialPreparation(generation) else { return }
        personStickers = stickers
    }

    // MARK: Scattered cover photos

    /// Sets scattered cover photos from the tunnel layer that landed on this day.
    /// Matches tunnel photos to this day's PhotoItems by asset identifier.
    func setTunnelCoverPhotos(from layer: TunnelLayer, drift: CGSize = .zero) {
        let itemByID = Dictionary(editorialItems.map { ($0.asset.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
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
            tunnelCoverPhoto = result.first?.item
            scatteredInitialDrift = drift
            let spreadRaw = UserDefaults.standard.string(forKey: "OneDay.tunnelSpread") ?? ""
            scatteredSpreadFactor = (TunnelSpread(rawValue: spreadRaw) ?? .medium).factor
        }
    }

    /// Generates scattered cover photos for non-tunnel days: picks 3-5 random
    /// photos and assigns tube-wall-like coordinates.
    private func computeScatteredCoverPhotos() {
        let photos = editorialItems.filter { !$0.isVideo }
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

    private func applyVisionGrouping(generation: UUID? = nil) async {
        let items = allItems
        guard items.count > 1 else { return }
        await VisionSimilarity.shared.warmUp(Array(items.prefix(150)))
        guard isCurrentFilterPreparation(generation) else { return }

        // Precompute Vision distances between consecutive items.
        var distances: [String: Float] = [:]
        for i in 1..<items.count {
            guard isCurrentFilterPreparation(generation) else { return }
            let a = items[i - 1], b = items[i]
            if let d = await VisionSimilarity.shared.distance(a, b) {
                distances["\(a.id)|\(b.id)"] = d
            }
        }
        guard isCurrentFilterPreparation(generation) else { return }
        visionDistances = distances
        rebuildSections()
    }

    // MARK: Route

    /// A chronological route stop: a geographic cluster of located items. Built
    /// purely from coordinates so it stays consistent with the map and is not
    /// affected by time-band sectioning. Revisits appear as separate stops.
    typealias RouteSegment = PhotoRouteSegment

    /// Reverse-geocoded place per route segment, keyed by segment id. A
    /// missing entry means the stop is still resolving.
    private var segmentPlaces: [String: PlaceNaming.StopPlace] = [:]

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
    /// same title merge into one stop; consecutive unresolvable stops merge
    /// into one placeholder.
    struct RouteStop: Identifiable {
        enum NameState: Equatable {
            case loading
            case resolved(String)
            case unavailable
        }

        let id: String
        let nameState: NameState
        let firstItemID: String
        let itemIDs: [String]

        var name: String? {
            if case .resolved(let title) = nameState { return title }
            return nil
        }
    }

    var routeStops: [RouteStop] {
        let segments = routeSegments
        guard !segments.isEmpty else { return [] }
        let titles = PlaceNaming.stopTitles(for: segments.map { segmentPlaces[$0.id] ?? .loading })
        var stops: [RouteStop] = []
        for (segment, title) in zip(segments, titles) {
            let state: RouteStop.NameState
            switch title {
            case .loading: state = .loading
            case .title(let name): state = .resolved(name)
            case .unavailable: state = .unavailable
            }
            // Only two real, identical names merge; loading or unavailable
            // stops always stay separate.
            if let last = stops.last, let lastName = last.name, case .resolved(let name) = state,
               lastName == name {
                stops[stops.count - 1] = RouteStop(id: last.id, nameState: last.nameState,
                                                   firstItemID: last.firstItemID,
                                                   itemIDs: last.itemIDs + segment.itemIDs)
            } else {
                stops.append(RouteStop(id: segment.id, nameState: state,
                                       firstItemID: segment.firstItemID,
                                       itemIDs: segment.itemIDs))
            }
        }
        return stops
    }

    /// Fully materialized stop names for the top selector and the map banner:
    /// resolved titles, "定位中…" while resolving, and "地点 N" only once the
    /// geocoder has definitively failed for that stop this session.
    var routeStopDisplayNames: [String] {
        routeStops.enumerated().map { index, stop in
            switch stop.nameState {
            case .resolved(let title): return title
            case .loading: return "定位中…"
            case .unavailable: return "地点 \(index + 1)"
            }
        }
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

    /// Resolves every route stop's place once, then applies the resulting
    /// titles to the already-built sections.
    private func resolveSegmentPlaces(generation: UUID? = nil) async {
        let segments = routeSegments
        guard !segments.isEmpty else { return }
        for segment in segments where segmentPlaces[segment.id] == nil {
            guard isCurrentFilterPreparation(generation) else { return }
            let loc = CLLocation(latitude: segment.coordinate.latitude,
                                 longitude: segment.coordinate.longitude)
            let resolution = await LocationResolver.shared.place(for: loc, priority: .pageContent)
            guard isCurrentFilterPreparation(generation) else { return }
            segmentPlaces[segment.id] = PlaceNaming.StopPlace(resolution)
        }
        applyPlaceNames()
    }

    /// Re-applies resolved stop titles to the sections. When same-titled
    /// stops merge (or a stop's failure changes the grouping), the body is
    /// rebuilt without animation; otherwise only the headings update in place
    /// so the layout and scroll position stay untouched.
    private func applyPlaceNames() {
        let similar: ((PhotoItem, PhotoItem) -> Bool)? =
            visionDistances.isEmpty ? nil : { [weak self] a, b in
                self?.visionSimilar(a, b) ?? false
            }
        let newSections = MagazineLayoutEngine.compose(
            allItems, similar: similar, enabled: enabledTemplates,
            policy: titleSegmentation, places: placeGroups())

        guard newSections.count == sections.count,
              zip(newSections, sections).allSatisfy({ new, old in
                  new.placeStopID == old.placeStopID && new.structure == old.structure
              }) else {
            sections = newSections
            Task { await computeSectionTints() }
            return
        }

        for index in sections.indices {
            sections[index].placeName = newSections[index].placeName
            sections[index].placeHeading = newSections[index].placeHeading
            sections[index].placeHeadingPending = newSections[index].placeHeadingPending
        }
    }

    /// Total travel distance along the trajectory, in kilometers.
    var travelKilometers: Double {
        routeDistanceKilometers(for: routeLocations)
    }

    private func routeDistanceKilometers(for locations: [CLLocation]) -> Double {
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
        guard item.sharedCapabilities.canFavorite else { return }
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
        guard item.sharedCapabilities.canHide else { return false }
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
        var all = PhotoActionService.shared.userAlbums()
        all.append(.hiddenAlbum)
        return orderedAlbums(all).filter { !disabledAlbumIDs.contains($0.id) }
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
        guard item.sharedCapabilities.canEditAlbums else { return false }
        do {
            try await PhotoActionService.shared.addToAlbum(identifier: album.id, assets: [item.asset])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func removeFromAlbum(_ album: AlbumInfo, item: PhotoItem) async -> Bool {
        guard item.sharedCapabilities.canEditAlbums else { return false }
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
        guard item.sharedCapabilities.canEditAlbums else { return }
        try? await PhotoActionService.shared.addToAlbum(named: name, assets: [item.asset])
    }

    /// Creates an empty album for configuration; does not add a photo.
    @discardableResult
    func createEmptyAlbum(named name: String) async -> AlbumInfo? {
        try? await PhotoActionService.shared.createAlbum(named: name)
    }

    func resolvePlaces(generation: UUID? = nil) async {
        // In place mode each section already carries its stop's resolved name.
        guard !hasRoute else { return }
        let targets = sections.compactMap { section -> (UUID, CLLocation)? in
            guard let location = section.anchorLocation else { return nil }
            return (section.id, location)
        }
        for (sectionID, location) in targets {
            guard isCurrentFilterPreparation(generation) else { return }
            guard case .resolved(let fields) = await LocationResolver.shared.place(
                for: location, priority: .pageContent) else { continue }
            guard isCurrentFilterPreparation(generation),
                  let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
            sections[index].placeName = PlaceNaming.photoTitle(fields)
        }
    }

    func perform(_ action: LibraryAction, on item: PhotoItem) async {
        let caps = item.sharedCapabilities
        switch action {
        case .toggleFavorite:
            guard caps.canFavorite else { return }
            await toggleFavorite(item)
        case .delete:
            guard caps.canDelete else { return }
            do {
                try await PhotoActionService.shared.delete([item.asset])
                remove(item)
            } catch { }
        case .addToAlbum(let name):
            guard caps.canEditAlbums else { return }
            try? await PhotoActionService.shared.addToAlbum(named: name, assets: [item.asset])
        case .pickAlbum:
            guard caps.canEditAlbums else { return }
            albumPickerItem = item
        }
    }

    func removeItems(ids: Set<String>) {
        guard allItemsUnfiltered.contains(where: { ids.contains($0.id) }) else { return }
        sourceRevision = UUID()
        allItemsUnfiltered.removeAll { ids.contains($0.id) }
        pendingSourceItems?.removeAll { ids.contains($0.id) }
        allItems.removeAll { ids.contains($0.id) }
        favoriteIDs.subtract(ids)
        hiddenIDs.subtract(ids)
        for id in ids { photoFrameColors.removeValue(forKey: id) }
        invalidateEditorialPreparation()
        applySharedFilter(animated: true, force: true)
        scheduleReprepareAfterFilterChange()
    }

    private func remove(_ item: PhotoItem) {
        removeItems(ids: [item.id])
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
