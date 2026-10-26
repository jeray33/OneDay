import SwiftUI
import Photos
import CoreLocation

@MainActor
@Observable
final class DayViewModel {
    let instanceID = UUID()
    let date: Date
    private(set) var sections: [MagazineSection]
    private(set) var allItems: [PhotoItem] {
        didSet {
            gridItemIDs = allItems.map(\.id)
            gridCaptions = allItems.map(\.caption)
            itemsRevision = UUID()
        }
    }
    private(set) var gridItemIDs: [String] = []
    private(set) var gridCaptions: [String?] = []
    private(set) var itemsRevision = UUID()
    private var similaritySettingsRevision = 0
    private var similarFoldingPreferences: SimilarPhotoFoldingPreferences {
        _ = similaritySettingsRevision
        return SimilarPhotoFoldingPreferences()
    }
    var similarFolding: SimilarPhotoFolding {
        get { similarFoldingPreferences.level }
        set { updateSimilarFolding { $0.select(newValue) } }
    }
    var similarFoldingEnabled: Bool {
        get { similarFoldingPreferences.isEnabled }
        set { updateSimilarFolding { $0.isEnabled = newValue } }
    }
    var similarFoldingThreshold: Float {
        get { similarFoldingPreferences.parameters.threshold }
        set { updateSimilarFolding { $0.setThreshold(newValue) } }
    }
    var similarFoldingWindow: TimeInterval {
        get { similarFoldingPreferences.parameters.window }
        set { updateSimilarFolding { $0.setWindow(newValue) } }
    }

    private func updateSimilarFolding(_ update: (inout SimilarPhotoFoldingPreferences) -> Void) {
        let previous = similarFoldingPreferences
        var settings = previous
        update(&settings)
        guard settings != previous else { return }
        settings.save()
        similaritySettingsRevision &+= 1
        expandedGroupIDs.removeAll()
        refreshVisualPresentation()
        // Parameter changes regroup cached features; do not restart inference.
        if settings.isEnabled != previous.isEnabled { prepareSimilarity() }
    }
    private(set) var expandedGroupIDs: Set<String> = []
    private var similarityTask: Task<Void, Never>?
    private var similarityGeneration = UUID()
    private var pendingSimilarityRefresh = false
    private var sharedVideoDuplicateTask: Task<Void, Never>?
    private var sharedVideoDuplicateGeneration = UUID()
    private var sharedVideoDuplicateIDs: Set<String> = []

    isolated deinit {
        sharedVideoDuplicateTask?.cancel()
        similarityTask?.cancel()
    }

    private func prepareSharedVideoDuplicates() {
        sharedVideoDuplicateTask?.cancel()
        let generation = UUID()
        sharedVideoDuplicateGeneration = generation
        guard includeSharedAlbums else { return }
        let items = allItemsUnfiltered
        sharedVideoDuplicateTask = Task { [weak self] in
            let ids = await SharedVideoDuplicateService.shared.duplicateIDs(in: items) { [weak self] ids in
                await self?.acceptSharedVideoDuplicates(ids, generation: generation, final: false)
            }
            guard !Task.isCancelled else { return }
            self?.acceptSharedVideoDuplicates(ids, generation: generation, final: true)
        }
    }

    private func acceptSharedVideoDuplicates(_ ids: Set<String>, generation: UUID, final: Bool) {
        let ids = SharedVideoDuplicatePolicy.updatedDuplicateIDs(
            confirmed: sharedVideoDuplicateIDs, reported: ids, isFinal: final)
        guard !Task.isCancelled, sharedVideoDuplicateGeneration == generation,
              ids != sharedVideoDuplicateIDs else { return }
        sharedVideoDuplicateIDs = ids
        // The existing filter defers changes until preview dismissal.
        applySharedFilter(animated: false)
        if selected == nil { scheduleReprepareAfterFilterChange() }
    }

    func toggleSimilarGroup(_ id: String) {
        if !expandedGroupIDs.insert(id).inserted { expandedGroupIDs.remove(id) }
    }

    func gridCellID(forItemID id: String) -> String {
        for section in sections {
            for block in section.blocks where block.items.contains(where: { $0.id == id }) {
                if let groupID = block.groupID, !expandedGroupIDs.contains(groupID) {
                    return block.representativeID ?? id
                }
            }
        }
        return id
    }

    private func prepareSimilarity() {
        similarityTask?.cancel()
        let generation = UUID()
        similarityGeneration = generation
        isPreparingFeatured = showsFeaturedTab
        guard similarFolding != .off || showsFeaturedTab else { return }
        let items = similarFolding == .off
            ? Self.filterShared(allItemsUnfiltered, includeShared: includeSharedAlbums).filter {
                MediaFilter.category(for: $0.asset) == .photoVideo && !sharedVideoDuplicateIDs.contains($0.id)
            }
            : allItemsUnfiltered
        similarityTask = Task { [weak self] in
            await SimilarityFeatureService.shared.prepare(items) { [weak self] in
                await self?.acceptVisualAnalysis(generation: generation, finished: false)
            }
            guard !Task.isCancelled, let self, self.similarityGeneration == generation else { return }
            self.acceptVisualAnalysis(generation: generation, finished: true)
        }
    }

    private func acceptVisualAnalysis(generation: UUID, finished: Bool) {
        guard !Task.isCancelled, similarityGeneration == generation else { return }
        if finished { isPreparingFeatured = false }
        refreshVisualPresentation()
    }

    private func refreshVisualPresentation() {
        let previousIDs = allItems.map(\.id)
        applySharedFilter(animated: false)
        if selected != nil {
            pendingSimilarityRefresh = true
        } else if previousIDs != allItems.map(\.id) {
            scheduleReprepareAfterFilterChange()
        } else {
            rebuildSections(animated: false)
        }
    }
    var selected: PhotoItem? {
        didSet {
            schedulePlacePresentation()
            if selected == nil, pendingSimilarityRefresh {
                pendingSimilarityRefresh = false
                rebuildSections(animated: false)
            }
            guard selected == nil,
                  pendingClassificationRefresh || pendingSourceItems != nil else { return }
            // Let the hero flight finish restoring its source cell first.
            Task { [weak self] in
                guard let self, self.selected == nil else { return }
                if let items = self.pendingSourceItems {
                    self.pendingSourceItems = nil
                    self.replaceSourceItems(items)
                }
                if self.pendingClassificationRefresh {
                    self.pendingClassificationRefresh = false
                    self.applySharedFilter(animated: false, force: true)
                    self.scheduleReprepareAfterFilterChange()
                }
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
        sharedVideoDuplicateIDs.removeAll()
        prepareSharedVideoDuplicates()
        allItems = replacing(allItems)
        if let pendingSourceItems { self.pendingSourceItems = replacing(pendingSourceItems) }
        if selected?.id == id { selected = replacement }
        coverPhotos = replacing(coverPhotos)
        coverCandidates = replacing(coverCandidates)
        if tunnelCoverPhoto?.id == id { tunnelCoverPhoto = replacement }
        if manualCoverPhoto?.id == id { manualCoverPhoto = replacement }
        prepareSimilarity()
        sourceRevision = UUID()
        invalidateEditorialPreparation()
        recomputeRouteDerived()
        rebuildSections(animated: false)
        scheduleReprepareAfterFilterChange()
    }

    private var favoriteIDs: Set<String>
    private var hiddenIDs: Set<String>

    // MARK: Page appearance
    private static let backgroundKey   = "OneDay.pageBackground"
    private static let borderWidthKey  = "OneDay.borderWidth"
    private static let photoShadowKey  = "OneDay.photoShadow"
    private static let photoCornerRadiusKey = "OneDay.photoCornerRadius"
    private static let gridHorizontalSpacingKey = "OneDay.gridHorizontalSpacing"
    private static let gridVerticalSpacingKey = "OneDay.gridVerticalSpacing"
    private static let gridLazyEnabledKey = "OneDay.gridLazyEnabled"
    private static let coverDateFontKey  = CoverDateFont.storageKey
    private static let scrubberMarksKey  = "OneDay.scrubberSectionMarks"
    private static let scrubberTickHapticsKey = "OneDay.scrubberTickHaptics"
    private static let sectionTitleSizeKey = "OneDay.sectionTitleSize"
    private static let photoCaptionsKey  = "OneDay.photoCaptions"
    private static let showDayInsightsKey = "OneDay.showDayInsights"
private static let albumTagBarKey    = "OneDay.albumTagBar"
    private static let disabledAlbumIDsKey = "OneDay.disabledAlbumIDs"
    private static let albumTagOrderKey  = "OneDay.albumTagOrder"
    private static let includeSharedAlbumsKey = "OneDay.includeSharedAlbums"

    var background: PageBackground {
        didSet {
            UserDefaults.standard.set(background.rawValue, forKey: Self.backgroundKey)
        }
    }
    var backCoverBackground: BackCoverBackground {
        didSet {
            UserDefaults.standard.set(backCoverBackground.rawValue, forKey: BackCoverBackground.storageKey)
        }
    }
    var borderWidth: PhotoBorderWidth {
        didSet { UserDefaults.standard.set(borderWidth.rawValue, forKey: Self.borderWidthKey) }
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
    private var gridColumnPolicy: GridColumnPolicy {
        didSet { gridColumnPolicy.save() }
    }
    var gridArrangement: DayGridArrangement {
        didSet {
            UserDefaults.standard.set(gridArrangement.rawValue, forKey: DayGridArrangement.storageKey)
        }
    }
    var photoSideSpacing: DayPhotoSideSpacing {
        didSet {
            UserDefaults.standard.set(photoSideSpacing.rawValue, forKey: DayPhotoSideSpacing.storageKey)
        }
    }
    var placeCardRatio: PlaceCardRatio {
        didSet {
            UserDefaults.standard.set(placeCardRatio.rawValue, forKey: PlaceCardRatio.storageKey)
        }
    }
    var placeCardStyle: PlaceCardStyle {
        didSet {
            UserDefaults.standard.set(placeCardStyle.rawValue, forKey: PlaceCardStyle.storageKey)
        }
    }
    var placeCardFlow: PlaceCardFlow {
        didSet {
            UserDefaults.standard.set(placeCardFlow.rawValue, forKey: PlaceCardFlow.storageKey)
        }
    }
    var showsPlaceCardFlowOption: Bool {
        PlaceCardFlow.isApplicable(
            arrangement: gridArrangement, placeEnabled: titlePlaceSegmentation,
            form: placeSegmentationForm
        )
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
    /// Whether the aligned grid uses LazyVGrid (only near-viewport rows are
    /// instantiated). Images are viewport-gated in every layout regardless;
    /// this only trades cell materialization for scroll fluidity.
    var gridLazyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gridLazyEnabled, forKey: Self.gridLazyEnabledKey)
        }
    }
    var coverDateFont: CoverDateFont {
        didSet { UserDefaults.standard.set(coverDateFont.rawValue, forKey: Self.coverDateFontKey) }
    }
    /// Whether the scrubber draws (and buzzes on) section-start marks.
    var showScrubberSectionMarks: Bool {
        didSet { UserDefaults.standard.set(showScrubberSectionMarks, forKey: Self.scrubberMarksKey) }
    }
    /// Whether scrubbing across ordinary ticks gives a light haptic tick.
    var scrubberTickHaptics: Bool {
        didSet { UserDefaults.standard.set(scrubberTickHaptics, forKey: Self.scrubberTickHapticsKey) }
    }
    var sectionTitleSize: SectionTitleSize {
        didSet { UserDefaults.standard.set(sectionTitleSize.rawValue, forKey: Self.sectionTitleSizeKey) }
    }
    private var titleSegmentation: TitleSegmentationPolicy {
        didSet {
            titleSegmentation.save()
            rebuildSections(animated: oldValue.form == .title && titleSegmentation.form == .title)
        }
    }
    var placeSegmentationForm: TitleSegmentationPolicy.Form {
        get { titleSegmentation.form }
        set { titleSegmentation.form = newValue }
    }
    var showsNestedTimeSegmentationOption: Bool { titleSegmentation.showsNestedTimeOption }
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
    var routeMapStyle: RouteMapStyle {
        didSet { UserDefaults.standard.set(routeMapStyle.rawValue, forKey: RouteMapStyle.storageKey) }
    }
    /// Whether to show each photo's caption/description beneath it in the photo
    /// page and in the photo preview.
    var showPhotoCaptions: Bool {
        didSet { UserDefaults.standard.set(showPhotoCaptions, forKey: Self.photoCaptionsKey) }
    }
    /// Whether the insights strip (steps / weather / mood) appears under the
    /// route map. Turning it back on kicks off a load if nothing is cached.
    var showDayInsights: Bool {
        didSet {
            UserDefaults.standard.set(showDayInsights, forKey: Self.showDayInsightsKey)
            if showDayInsights, insights == nil { loadInsights() }
        }
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
            prepareSharedVideoDuplicates()
            if showsFeaturedTab { prepareSimilarity() }
            scheduleReprepareAfterFilterChange()
        }
    }
    private var mediaTabs: DayMediaTabs<PhotoItem>
    private(set) var selectedMediaTab: DayMediaTab?
    var availableMediaTabs: [DayMediaTab] { mediaTabs.availableTabs }
    var showsMediaTabs: Bool { mediaTabs.showsTabBar }
    var showsFeaturedTab = FeaturedMediaPolicy.isEnabled() {
        didSet {
            guard oldValue != showsFeaturedTab else { return }
            UserDefaults.standard.set(showsFeaturedTab, forKey: FeaturedMediaPolicy.enabledKey)
            refreshVisualPresentation()
            prepareSimilarity()
        }
    }
    var featuredAmount = FeaturedMediaAmount.saved() {
        didSet {
            guard oldValue != featuredAmount else { return }
            featuredAmount.save()
            // Scores and feature prints are reused; no additional image reads.
            refreshVisualPresentation()
        }
    }
    private(set) var isPreparingFeatured = false

    private static func makeMediaTabs(_ items: [PhotoItem], featuredEnabled: Bool) -> DayMediaTabs<PhotoItem> {
        var featuredIDs = Set<String>()
        if featuredEnabled {
            let candidates = items.filter { MediaFilter.category(for: $0.asset) == .photoVideo }
            let groups = DaySectionComposer.similarGroups(candidates, ignoringOffSwitch: true)
            let best = FeaturedMediaPolicy.curatedItems(
                in: groups, amount: FeaturedMediaAmount.saved(), isVideo: \.isVideo
            ) { SimilarityFeatureStore.shared.score($0) }
            featuredIDs = Set(best.map(\.id))
        }
        return DayMediaTabs(items: items, featuredEnabled: featuredEnabled,
                            featured: { featuredIDs.contains($0.id) }) { MediaFilter.category(for: $0.asset) }
    }

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
    /// Highest-priority category's items in chronological order. Stills from
    /// it are ranked into coverPhotos; a still-free tier covers with its
    /// first video frame.
    private(set) var coverCandidates: [PhotoItem] = []
    private(set) var tunnelCoverPhoto: PhotoItem?
    /// The user's manually chosen cover for this day (persisted per calendar
    /// day). Takes priority over the tunnel landing photo and the automatic
    /// ranking; nil when unset or when the saved asset is no longer on the day.
    private(set) var manualCoverPhoto: PhotoItem?
    private var heroHue: (hue: CGFloat, saturation: CGFloat)?

    /// Nil while the sharpest still is still being ranked. Tiers without
    /// stills use their first video's still frame; a manual cover wins over both.
    var photoCoverItem: PhotoItem? {
        if let photo = manualCoverPhoto ?? tunnelCoverPhoto ?? coverPhotos.first { return photo }
        guard !coverCandidates.contains(where: { !$0.isVideo }) else { return nil }
        return coverCandidates.first
    }

    var backCoverGradient: Gradient {
        BackCoverGradient.gradient(
            hue: heroHue.map { Double($0.hue) }, saturation: Double(heroHue?.saturation ?? 0))
    }

    var backCoverColorScheme: ColorScheme {
        backCoverBackground == .immersive ? .dark : .light
    }

    private(set) var brightColor: Color = .white

    var pageBackgroundColor: Color {
        backgroundColor(for: background)
    }

    func backgroundColor(for background: PageBackground) -> Color {
        switch background {
        case .paper:    return Color(white: 0.96)
        case .pureWhite: return Color(white: 1.0)
        case .bright:   return brightColor
        }
    }

    var pageColorScheme: ColorScheme {
        .light
    }

    /// Near-white pastel wash, preserving the former 明快2 palette.
    private func brightTint(h: CGFloat, s: CGFloat) -> Color {
        let sat = max(min(s, 0.3), 0.2)
        let color = UIColor(hue: h, saturation: sat, brightness: 1.0, alpha: 1)
        return Color(uiColor: color)
    }

    init(date: Date, items: [PhotoItem]) {
        DayAppearancePreferences.migrateLegacySettings()
        self.date = date
        let sortedItems = SharedVideoDuplicatePolicy.unique(items, id: \.id).sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        self.favoriteIDs = Set(items.filter { $0.isFavorite }.map(\.id))
        self.hiddenIDs = Set(items.filter { $0.isHidden }.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Self.backgroundKey)
        self.background = PageBackground(savedValue: saved)
        self.backCoverBackground = BackCoverBackground(
            savedValue: UserDefaults.standard.string(forKey: BackCoverBackground.storageKey))
        let savedWidth = UserDefaults.standard.string(forKey: Self.borderWidthKey)
        self.borderWidth = PhotoBorderWidth(rawValue: savedWidth ?? "") ?? .max
        let savedShadow = UserDefaults.standard.string(forKey: Self.photoShadowKey)
        self.photoShadow = PhotoShadowLevel(rawValue: savedShadow ?? "") ?? .max
        let savedCornerRadius = UserDefaults.standard.string(forKey: Self.photoCornerRadiusKey)
        self.photoCornerRadius = PhotoCornerRadius(rawValue: savedCornerRadius ?? "") ?? .none
        self.coverDateFont = CoverDateFont(rawValue:         UserDefaults.standard.string(forKey: Self.coverDateFontKey)  ?? "") ?? .impact
        self.showScrubberSectionMarks = UserDefaults.standard.object(forKey: Self.scrubberMarksKey) as? Bool ?? true
        self.scrubberTickHaptics = UserDefaults.standard.object(forKey: Self.scrubberTickHapticsKey) as? Bool ?? true
        self.sectionTitleSize = SectionTitleSize(rawValue: UserDefaults.standard.string(forKey: Self.sectionTitleSizeKey) ?? "") ?? .xlarge
        self.routeMapStyle = RouteMapStyle(
            savedValue: UserDefaults.standard.string(forKey: RouteMapStyle.storageKey))
self.showPhotoCaptions = UserDefaults.standard.object(forKey: Self.photoCaptionsKey) as? Bool ?? false
self.showAlbumTagBar = UserDefaults.standard.object(forKey: Self.albumTagBarKey) as? Bool ?? true
        self.showDayInsights = UserDefaults.standard.object(forKey: Self.showDayInsightsKey) as? Bool ?? true
        let savedDisabled = UserDefaults.standard.stringArray(forKey: Self.disabledAlbumIDsKey) ?? []
        self.disabledAlbumIDs = Set(savedDisabled)
        self.albumTagOrder = UserDefaults.standard.stringArray(forKey: Self.albumTagOrderKey) ?? []
        self.gridColumnPolicy = GridColumnPolicy(itemCount: items.count)
        self.gridArrangement = DayGridArrangement(
            savedValue: UserDefaults.standard.string(forKey: DayGridArrangement.storageKey)
        )
        self.photoSideSpacing = DayPhotoSideSpacing(
            savedValue: UserDefaults.standard.string(forKey: DayPhotoSideSpacing.storageKey)
        )
        self.placeCardRatio = PlaceCardRatio(
            savedValue: UserDefaults.standard.string(forKey: PlaceCardRatio.storageKey)
        )
        self.placeCardStyle = PlaceCardStyle(
            savedValue: UserDefaults.standard.string(forKey: PlaceCardStyle.storageKey)
        )
        self.placeCardFlow = PlaceCardFlow(
            savedValue: UserDefaults.standard.string(forKey: PlaceCardFlow.storageKey)
        )
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
        // Compute the first-run preference and the section composition using only
        // local values; all `self.* = ...` writes are deferred to the very end
        // of init so phase-2 reads of `self` are never required mid-init.
        let savedShared = UserDefaults.standard.object(forKey: Self.includeSharedAlbumsKey) as? Bool ?? true
        let sharedItems = Self.filterShared(
            sortedItems, includeShared: savedShared)
        let tabs = Self.makeMediaTabs(sharedItems, featuredEnabled: FeaturedMediaPolicy.isEnabled())
        let selectedCategory = tabs.tabSelection(preserving: nil)
        let composedItems = tabs.items(inTab: selectedCategory)
        let segmentation = TitleSegmentationPolicy()
        let composedSections = DaySectionComposer.compose(composedItems, policy: segmentation)
        self.titleSegmentation = segmentation
        self.allItemsUnfiltered = sortedItems
        self.manualCoverPhoto = Self.resolveManualCover(in: sortedItems, date: date)
        self.allItems = composedItems
        self.gridItemIDs = composedItems.map(\.id)
        self.gridCaptions = composedItems.map(\.caption)
        self.includeSharedAlbums = savedShared
        self.mediaTabs = tabs
        self.selectedMediaTab = selectedCategory
        self.sections = composedSections
        recomputeRouteDerived()
        // Old multi-select choices no longer control the day body.
        UserDefaults.standard.removeObject(forKey: "OneDay.dayMediaCategories")
        if segmentation.form == .card {
            // Route boundaries are local; don't wait for colors or geocoding
            // before reserving the cards' final grid slots.
            rebuildSections(animated: false)
        }
    }

    var photoCount: Int { allItems.filter { !$0.isVideo }.count }
    var videoCount: Int { allItems.filter(\.isVideo).count }

    var friendSharedCount: Int {
        guard includeSharedAlbums else { return 0 }
        return DayMediaScope.friendSharedCount(
            from: allItemsUnfiltered, excluding: sharedVideoDuplicateIDs, id: \.id,
            isForeignShared: { $0.isForeignShared && DayMediaScope.isSupported($0.asset.mediaType) },
            isHidden: \.isHidden)
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

    /// Composed sections and blocks get fresh UUIDs; reusing the previous IDs
    /// (matched by first photo) keeps SwiftUI from recreating every grid cell,
    /// which would blank and reload the whole page on each rebuild.
    private func preservingIdentities(_ composed: [MagazineSection]) -> [MagazineSection] {
        var newSections = composed
        let oldSections = Dictionary(sections.compactMap { section in
            section.blocks.first?.items.first.map { ($0.id, section.id) }
        }, uniquingKeysWith: { first, _ in first })
        let oldBlocks = Dictionary(sections.flatMap(\.blocks).compactMap { block in
            block.items.first.map { ($0.id, block.id) }
        }, uniquingKeysWith: { first, _ in first })
        var usedSections = Set<UUID>(), usedBlocks = Set<UUID>()
        for section in newSections.indices {
            if let first = newSections[section].blocks.first?.items.first,
               let id = oldSections[first.id], usedSections.insert(id).inserted {
                newSections[section].id = id
            }
            for block in newSections[section].blocks.indices {
                if let first = newSections[section].blocks[block].items.first,
                   let id = oldBlocks[first.id], usedBlocks.insert(id).inserted {
                    newSections[section].blocks[block].id = id
                }
            }
        }
        return newSections
    }

    /// Rebuilds the body using the saved place/time segmentation choices.
    private func rebuildSections(animated: Bool = true) {
        let newSections = preservingIdentities(DaySectionComposer.compose(
            allItems,
            policy: titleSegmentation, places: placeGroups()))
        if gridArrangement == .waterfall || titleSegmentation.form == .card {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { sections = newSections }
        } else if animated {
            withAnimation(.easeInOut(duration: 0.4)) { sections = newSections }
        } else {
            sections = newSections
        }
    }

    // MARK: Shared-library filter

    /// Own shared contributions are always excluded; the toggle controls
    /// whether other people's shared photos join the own-library originals.
    static func filterShared(
        _ items: [PhotoItem],
        includeShared: Bool
    ) -> [PhotoItem] {
        DayMediaScope.bodyItems(
            from: items, includeShared: includeShared,
            isShared: { $0.isFromSharedLibrary },
            isOwnSharedContribution: { $0.isOwnSharedContribution })
    }

    func selectMediaTab(_ category: DayMediaTab) {
        guard selected == nil, category != selectedMediaTab,
              availableMediaTabs.contains(category) else { return }
        selectedMediaTab = category
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
        // Explicit removals must update the grid behind the preview too.
        guard selected == nil || force else {
            pendingClassificationRefresh = true
            return
        }
        let sharedItems = Self.filterShared(
            allItemsUnfiltered,
            includeShared: includeSharedAlbums).filter { !sharedVideoDuplicateIDs.contains($0.id) }
        mediaTabs = Self.makeMediaTabs(sharedItems, featuredEnabled: showsFeaturedTab)
        selectedMediaTab = mediaTabs.tabSelection(preserving: selectedMediaTab)
        let filtered = mediaTabs.items(inTab: selectedMediaTab)
        // Field-only changes (captions, favorites) must not rebuild the grid;
        // repeated rebuilds re-request evicted thumbnails and flash the page.
        guard force || filtered.map(\.contentVersion) != allItems.map(\.contentVersion) else { return }
        filterPreparationID = UUID()
        bodyPreparationTask?.cancel()
        if filtered.isEmpty {
            brightColor = .white
        }
        allItems = filtered
        recomputeRouteDerived()
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

    /// Refreshes only body-derived colors, places, and captions.
    fileprivate func reprepareAfterFilterChange(generation: UUID) async {
        async let color: Void = computePageColor(generation: generation)
        async let captions: Void = loadPhotoCaptions(generation: generation)
        await resolveSegmentPlaces(generation: generation)
        if isCurrentFilterPreparation(generation) { await resolvePlaces(generation: generation) }
        _ = await (color, captions)
    }

    // MARK: Preparation (places, pastel color, and captions)

    func prepare() async {
        prepareSharedVideoDuplicates()
        prepareSimilarity()
        loadInsights()
        // Start classification first so the cover can await its results.
        classifyDayImages()
        // This task has its own lifetime, so body-filter changes cannot abort it.
        Task { await prepareEditorial() }
        let generation = filterPreparationID
        guard isCurrentFilterPreparation(generation) else { return }
        rebuildSections(animated: false)
        async let color: Void = computePageColor(generation: generation)
        async let captions: Void = loadPhotoCaptions(generation: generation)
        await resolveSegmentPlaces(generation: generation)
        if isCurrentFilterPreparation(generation) { await resolvePlaces(generation: generation) }
        _ = await (color, captions)
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
        await computeHeroHue(generation: generation)
    }

    /// Real library updates replace the source; preview updates wait until close.
    func replaceSourceItems(_ items: [PhotoItem]) {
        guard selected == nil else {
            pendingSourceItems = items
            return
        }
        var sorted = SharedVideoDuplicatePolicy.unique(items.filter { !$0.isHidden }, id: \.id).sorted {
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
                    && new.contentVersion == old.contentVersion
                    && new.creationDate == old.creationDate
                    && new.isFromSharedLibrary == old.isFromSharedLibrary
                    && new.isOwnSharedContribution == old.isOwnSharedContribution
                    && new.captureTimeZone == old.captureTimeZone
            }
        allItemsUnfiltered = sorted
        manualCoverPhoto = Self.resolveManualCover(in: sorted, date: date)
        // Old content versions must never suppress newly edited/replaced media,
        // but untouched duplicates stay hidden: clearing them all would show
        // every duplicate again until the service re-confirms them.
        if !unchanged {
            let versions = Dictionary(sorted.map { ($0.id, $0.contentVersion) },
                                      uniquingKeysWith: { first, _ in first })
            sharedVideoDuplicateIDs = sharedVideoDuplicateIDs.filter { id in
                guard let version = versions[id] else { return false }
                return previousByID[id]?.contentVersion == version
            }
        }
        favoriteIDs = Set(sorted.filter(\.isFavorite).map(\.id))
        hiddenIDs = Set(sorted.filter(\.isHidden).map(\.id))
        guard !unchanged else { return }
        prepareSharedVideoDuplicates()
        prepareSimilarity()
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
        coverCandidates.removeAll { !sourceIDs.contains($0.id) }
        if let tunnelCoverPhoto, !sourceIDs.contains(tunnelCoverPhoto.id) {
            self.tunnelCoverPhoto = nil
        }
        Task { await prepareEditorial() }
    }

    /// Loads captions for all photos asynchronously and updates `allItems`.
    ///
    /// Native captions and cached values cost a selector call and two
    /// dictionary probes, so they are read for the whole day up front. The
    /// embedded-metadata fallback reads whole image files, so it runs strictly
    /// bounded (four at a time), local-only, and never re-attempts an asset
    /// this session has already ruled out.
    private func loadPhotoCaptions(generation: UUID? = nil) async {
        let items = allItems
        guard !items.isEmpty else { return }

        let captionsByID = await captionBatch(items, embeddedFallback: false)
        guard isCurrentFilterPreparation(generation) else { return }
        if !captionsByID.isEmpty {
            applyCaptions(captionsByID)
        }

        // The embedded fallback only applies to caption-less images.
        let pending = items.filter {
            captionsByID[$0.id] == nil && $0.asset.mediaType == .image
        }
        guard !pending.isEmpty else { return }

        let embedded = await captionBatch(pending, embeddedFallback: true)
        guard !embedded.isEmpty, isCurrentFilterPreparation(generation) else { return }
        applyCaptions(embedded)
    }

    private func captionBatch(_ items: [PhotoItem], embeddedFallback: Bool) async -> [String: String] {
        var captions: [String: String] = [:]
        var next = 0
        await withTaskGroup(of: (String, String?).self) { group in
            @MainActor func enqueueNext() {
                guard !Task.isCancelled, next < items.count else { return }
                let item = items[next]
                let id = item.id
                let asset = item.asset
                next += 1
                group.addTask {
                    let caption = await PhotoCaptionManager.shared.caption(
                        for: asset, embeddedFallback: embeddedFallback, allowsNetworkAccess: false)
                    return (id, caption)
                }
            }
            for _ in 0..<min(4, items.count) { enqueueNext() }
            for await (id, caption) in group {
                if let caption { captions[id] = caption }
                enqueueNext()
            }
        }
        return captions
    }

    /// Propagates found captions into the body items, the unfiltered source,
    /// and the composed sections — O(n) per collection through the id
    /// dictionary, writing only where a caption actually changed.
    private func applyCaptions(_ captionsByID: [String: String]) {
        guard !captionsByID.isEmpty else { return }
        var updated = allItems
        var changed = false
        for index in updated.indices {
            guard let caption = captionsByID[updated[index].id],
                  updated[index].caption != caption else { continue }
            updated[index].caption = caption
            changed = true
        }
        if changed {
            allItems = updated
            recomputeRouteDerived()
        }
        for index in allItemsUnfiltered.indices {
            if let caption = captionsByID[allItemsUnfiltered[index].id],
               allItemsUnfiltered[index].caption != caption {
                allItemsUnfiltered[index].caption = caption
            }
        }
        // Propagate into the composed sections so every rendered copy of a
        // PhotoItem carries the caption.
        var updatedSections = sections
        var sectionsChanged = false
        for sIndex in updatedSections.indices {
            for bIndex in updatedSections[sIndex].blocks.indices {
                for iIndex in updatedSections[sIndex].blocks[bIndex].items.indices {
                    let id = updatedSections[sIndex].blocks[bIndex].items[iIndex].id
                    if let caption = captionsByID[id],
                       updatedSections[sIndex].blocks[bIndex].items[iIndex].caption != caption {
                        updatedSections[sIndex].blocks[bIndex].items[iIndex].caption = caption
                        sectionsChanged = true
                    }
                }
            }
        }
        if sectionsChanged { sections = updatedSections }
    }

    private func computePageColor(generation: UUID? = nil) async {
        let items = allItems
        guard let first = items.first(where: { !$0.isVideo }) ?? items.first else { return }
        guard let image = await ImageLoader.shared.thumbnail(asset: first.asset,
                                                            size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else { return }
        guard isCurrentFilterPreparation(generation) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        withAnimation(.easeInOut(duration: 0.3)) {
            brightColor = brightTint(h: h, s: s)
        }
    }

    // MARK: Cover

    /// Picks the 2 sharpest/best-composed stills of the preferred category:
    /// camera photos and videos first, then other images, then screenshots
    /// and recordings.
    private func computeCoverPhotos(generation: UUID) async {
        guard isCurrentEditorialPreparation(generation) else { return }
        let items = editorialItems
        guard !items.isEmpty else { coverPhotos = []; coverCandidates = []; return }
        guard coverPhotos.isEmpty else { return }
        await awaitDayClassificationIfDecisive(items: items, generation: generation)
        guard isCurrentEditorialPreparation(generation) else { return }
        let tier = CoverSelectionPolicy.coverCategory(
            among: items.lazy.compactMap { MediaFilter.category(for: $0.asset) })
        let candidates = items.filter { MediaFilter.category(for: $0.asset) == tier }
        coverCandidates = candidates
        let photos = candidates.filter { !$0.isVideo }
        guard photos.count > 2 else { coverPhotos = photos; return }
        let sample = CoverSelectionPolicy.sampleIndices(count: photos.count).map { photos[$0] }
        let ranked = await PhotoSharpnessRanker.shared.rank(assets: sample.map(\.asset), top: 2)
        guard isCurrentEditorialPreparation(generation) else { return }
        coverPhotos = ranked.map { sample[$0] }
    }

    /// Unknown classifications default to 照片和视频, so the cover tier is
    /// only misjudged when nothing on the day is provably camera media. Wait
    /// briefly for the day's own classification in that case, so a screenshot
    /// or download cannot win the cover merely because it was read first.
    private func awaitDayClassificationIfDecisive(items: [PhotoItem], generation: UUID) async {
        let store = ImageClassificationStore.shared
        func hasPending() -> Bool {
            items.contains { item in
                let asset = item.asset
                return MediaFilter.needsAutomaticClassification(asset)
                    && store.override(for: asset.localIdentifier) == .automatic
                    && store.classification(
                        for: asset.localIdentifier,
                        modificationDate: asset.modificationDate
                    ) == .unknown
            }
        }
        func hasGuaranteedCameraMedia() -> Bool {
            items.contains { item in
                let asset = item.asset
                if asset.representsBurst || MediaFilter.hasPhotoSubtype(asset.mediaSubtypes)
                    || MediaFilter.hasCameraVideoSubtype(asset.mediaSubtypes) { return true }
                return store.classification(
                    for: asset.localIdentifier,
                    modificationDate: asset.modificationDate
                ) == .photo
            }
        }
        guard !hasGuaranteedCameraMedia(), hasPending() else { return }
        if dayClassificationTask == nil { classifyDayImages() }
        // Bounded: unreachable (cloud-only) assets never finish classifying.
        let deadline = Date().addingTimeInterval(4)
        while hasPending(), !hasGuaranteedCameraMedia(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard isCurrentEditorialPreparation(generation) else { return }
        }
    }

    /// Keeps the existing hero-photo source for the immersive back cover.
    private func computeHeroHue(generation: UUID) async {
        guard let hero = manualCoverPhoto ?? coverPhotos.first ?? coverCandidates.first ?? editorialItems.first,
              let image = await ImageLoader.shared.thumbnail(
                asset: hero.asset, size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else {
            guard isCurrentEditorialPreparation(generation) else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                heroHue = nil
            }
            return
        }
        guard isCurrentEditorialPreparation(generation) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        withAnimation(.easeInOut(duration: 0.3)) {
            heroHue = (h, s)
        }
    }

    /// Keep the landed tunnel photo as the photo cover's hero.
    func setTunnelCoverPhoto(from layer: TunnelLayer) {
        let itemsByID = Dictionary(editorialItems.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        tunnelCoverPhoto = layer.photos.lazy.compactMap { itemsByID[$0.assetIdentifier] }.first
    }

    /// Resolves the persisted manual cover against the day's source items.
    /// The saved asset no longer being on the day simply yields nil, so the
    /// automatic selection takes over again.
    private static func resolveManualCover(in items: [PhotoItem], date: Date) -> PhotoItem? {
        guard let id = ManualCoverStore.shared.coverID(for: date) else { return nil }
        return items.first { $0.id == id }
    }

    /// Persists the user's cover choice for this day and refreshes the hero
    /// hue off the new cover. Returns false when the item already is the cover.
    @discardableResult
    func setCover(_ item: PhotoItem) -> Bool {
        guard manualCoverPhoto?.id != item.id else { return false }
        ManualCoverStore.shared.setCover(item.asset.localIdentifier, for: date)
        manualCoverPhoto = allItemsUnfiltered.first { $0.id == item.id } ?? item
        let generation = editorialPreparationID
        Task { [weak self] in
            await self?.computeHeroHue(generation: generation)
        }
        return true
    }

    /// True when at least one located photo/video exists (map is worth showing).
    var hasAnyLocation: Bool { routeFacts().hasAnyLocation }

    /// Centroid coordinate of each route stop (one dot per stop on the map).
    var routeStopCoordinates: [CLLocationCoordinate2D] { routeFacts().coordinates }

    /// Uses the current preview item, independent of the day and cover colors.
    func previewGradient(for item: PhotoItem) async -> Gradient {
        guard let image = await ImageLoader.shared.thumbnail(
                asset: item.asset, size: CGSize(width: 48, height: 48)),
              let base = image.averageColor else { return BackCoverGradient.gradient() }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return BackCoverGradient.gradient(hue: Double(h), saturation: Double(s))
    }

    // MARK: Route

    /// A chronological route stop: a geographic cluster of located items. Built
    /// purely from coordinates so it stays consistent with the map and is not
    /// affected by time-band sectioning. Revisits appear as separate stops.
    typealias RouteSegment = PhotoRouteSegment

    /// Reverse-geocoded place per route segment, keyed by segment id. A
    /// missing entry means the stop is still resolving.
    private var segmentPlaces: [String: PlaceNaming.StopPlace] = [:]
    @ObservationIgnored private var segmentPlaceLocations: [String: CLLocation] = [:]
    @ObservationIgnored private var routePlaceRequestID = UUID()
    @ObservationIgnored private var routeRefinementTask: Task<Void, Never>?
    @ObservationIgnored private var placePresentationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSegmentPlaces: [String: PlaceNaming.StopPlace] = [:]
    @ObservationIgnored private var placeInteraction = DayPlaceInteractionState()
    @ObservationIgnored private var dayViewActive = false
    @ObservationIgnored var beforePlacePresentation: (() -> Void)?
    private(set) var placesLayoutRevision = UUID()

    func resumePlaceUpdates() {
        dayViewActive = true
        schedulePlacePresentation()
    }

    func stopPlaceUpdates() {
        dayViewActive = false
        routeRefinementTask?.cancel()
        routeRefinementTask = nil
        placePresentationTask?.cancel()
        placePresentationTask = nil
        beforePlacePresentation = nil
        placeInteraction = DayPlaceInteractionState()
    }

    func setPlaceInteraction(_ activity: DayPlaceInteractionState.Activity, active: Bool) {
        placeInteraction.set(activity, active: active)
        schedulePlacePresentation()
    }

    private func stagePlace(_ resolution: LocationResolver.Resolution, for id: String) {
        let current = pendingSegmentPlaces[id] ?? segmentPlaces[id] ?? .loading
        let next = PlaceNaming.refinedPlace(current, with: resolution)
        guard next != current else { return }
        pendingSegmentPlaces[id] = next
        schedulePlacePresentation()
    }

    private func schedulePlacePresentation() {
        placePresentationTask?.cancel()
        placePresentationTask = nil
        guard dayViewActive, placeInteraction.isIdle, selected == nil,
              !pendingSegmentPlaces.isEmpty else { return }
        placePresentationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            guard let self, self.dayViewActive, self.placeInteraction.isIdle,
                  self.selected == nil, !Task.isCancelled else { return }
            let next = self.segmentPlaces.merging(self.pendingSegmentPlaces) { _, new in new }
            self.pendingSegmentPlaces.removeAll()
            let nextStops = Self.mergedStops(for: self.routeSegments, places: next)
            let changesLayout = nextStops != self.routeStops
            if changesLayout { self.beforePlacePresentation?() }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.segmentPlaces = next
                self.recomputeRouteDerived()
                if changesLayout {
                    self.placesLayoutRevision = UUID()
                    self.applyPlaceNames()
                }
            }
            self.placePresentationTask = nil
        }
    }

    /// Every route fact derived from the body items and the resolved stop
    /// names. Recomputed whenever either changes (`recomputeRouteDerived`)
    /// so layout code reading these stays O(1); the map banner and the cover
    /// read them on every scroll frame.
    private struct RouteDerived {
        let locations: [CLLocation]
        let segments: [RouteSegment]
        let stops: [RouteStop]
        let displayNames: [String]
        let coordinates: [CLLocationCoordinate2D]
        let kilometers: Double
        let hasAnyLocation: Bool
    }

    private var routeDerived: RouteDerived?

    /// Rebuilds the derived route facts. Called at every point the body items
    /// or resolved stop names change, never from a read.
    private func recomputeRouteDerived() {
        let items = allItems
        let locations = items.compactMap(\.location)
        let segments = PhotoRoute.segments(for: items)
        let stops = Self.mergedStops(for: segments, places: segmentPlaces)
        routeDerived = RouteDerived(
            locations: locations,
            segments: segments,
            stops: stops,
            displayNames: Self.displayNames(for: stops),
            coordinates: segments.map(\.coordinate),
            kilometers: routeDistanceKilometers(for: locations),
            hasAnyLocation: !locations.isEmpty)
    }

    private func routeFacts() -> RouteDerived {
        if let routeDerived { return routeDerived }
        recomputeRouteDerived()
        return routeDerived ?? RouteDerived(
            locations: [], segments: [], stops: [], displayNames: [],
            coordinates: [], kilometers: 0, hasAnyLocation: false)
    }

    /// Real trajectory: every located photo/video in chronological order.
    var routeLocations: [CLLocation] { routeFacts().locations }

    /// Geographic clustering of located items into ordered stops (route mode:
    /// a returning location yields a new stop). A new stop starts when an item
    /// is farther than 200m from the running centroid of the
    /// current stop.
    var routeSegments: [RouteSegment] { routeFacts().segments }

    /// A displayed route stop. Consecutive segments that resolve to the exact
    /// same title merge as they resolve. Unnamed stops retain their identities.
    struct RouteStop: Identifiable, Equatable {
        enum NameState: Equatable {
            case loading
            case resolved(String)
            case unavailable
        }

        let id: String
        let nameState: NameState
        let itemIDs: [String]

        var name: String? {
            switch nameState {
            case .resolved(let title): return title
            case .loading, .unavailable: return nil
            }
        }
    }

    var routeStops: [RouteStop] { routeFacts().stops }

    /// Consecutive segments that resolve to the exact same title merge into
    /// one stop; consecutive unresolvable ones stay separate. Only two real,
    /// identical names merge; loading or unavailable stops never do.
    private static func mergedStops(
        for segments: [RouteSegment], places: [String: PlaceNaming.StopPlace]
    ) -> [RouteStop] {
        guard !segments.isEmpty else { return [] }
        let titles = PlaceNaming.stopTitles(for: segments.map { places[$0.id] ?? .loading })
        return PlaceNaming.stopGroups(for: titles).map { indices in
            let first = indices[0]
            let state: RouteStop.NameState
            switch titles[first] {
            case .loading: state = .loading
            case .title(let name): state = .resolved(name)
            case .unavailable: state = .unavailable
            }
            return RouteStop(id: segments[first].id, nameState: state,
                             itemIDs: indices.flatMap { segments[$0].itemIDs })
        }
    }

    /// Fully materialized stop names for the map banner:
    /// resolved titles and distinct loading/failure placeholders.
    var routeStopDisplayNames: [String] { routeFacts().displayNames }

    private static func displayNames(for stops: [RouteStop]) -> [String] {
        stops.enumerated().map { index, stop in
            switch stop.nameState {
            case .resolved(let title): return title
            case .loading: return PlaceNaming.loadingTitle
            case .unavailable: return "地点 \(index + 1)"
            }
        }
    }

    var hasRoute: Bool { routeFacts().stops.count >= 2 }

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

    /// Foreign seeds come entirely from local GeoNames/cache work. Online
    /// refinement then runs independently at background priority.
    private func resolveSegmentPlaces(generation: UUID? = nil) async {
        let segments = routeSegments
        guard !segments.isEmpty, isCurrentFilterPreparation(generation) else { return }
        let requestID = UUID()
        routeRefinementTask?.cancel()
        pendingSegmentPlaces.removeAll()
        routePlaceRequestID = requestID
        let targets = segments.map {
            (id: $0.id, location: CLLocation(
                latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude))
        }
        for target in targets {
            if let old = segmentPlaceLocations[target.id],
               old.distance(from: target.location) > PlaceNaming.reuseMeters {
                segmentPlaces[target.id] = nil
            }
            segmentPlaceLocations[target.id] = target.location
        }

        let resolver = LocationResolver.shared
        let seeds = await resolver.initialDayPlaces(for: targets.map(\.location))
        guard isCurrentFilterPreparation(generation), routePlaceRequestID == requestID else { return }
        for (target, seed) in zip(targets, seeds) {
            if let fields = seed.fields { stagePlace(.resolved(fields), for: target.id) }
        }
        let pending = zip(targets, seeds).filter { $0.1.needsOnline }
        guard !pending.isEmpty else { return }
        routeRefinementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.routePlaceRequestID == requestID { self.routeRefinementTask = nil }
            }
            var next = 0
            await withTaskGroup(of: (String, LocationResolver.Resolution).self) { group in
                @MainActor func enqueueNext() {
                    guard !Task.isCancelled, next < pending.count else { return }
                    let (target, seed) = pending[next]
                    next += 1
                    group.addTask {
                        let resolution: LocationResolver.Resolution
                        if seed.isForeign {
                            resolution = await resolver.refineForeignPlace(for: target.location, initial: seed.fields)
                        } else {
                            resolution = await resolver.placeWithRetries(
                                for: target.location, priority: .pageContent, allowsOfflineFallback: true)
                        }
                        return (target.id, resolution)
                    }
                }
                for _ in 0..<min(4, pending.count) { enqueueNext() }
                for await (id, resolution) in group {
                    guard self.isCurrentFilterPreparation(generation),
                          self.routePlaceRequestID == requestID, self.dayViewActive else {
                        group.cancelAll()
                        break
                    }
                    self.stagePlace(resolution, for: id)
                    enqueueNext()
                }
            }
        }
    }

    /// Re-applies resolved stop titles to the sections. When same-titled
    /// stops merge (or a stop's failure changes the grouping), the body is
    /// rebuilt without animation; otherwise only the headings update in place
    /// so the layout and scroll position stay untouched.
    private func applyPlaceNames() {
        let newSections = preservingIdentities(DaySectionComposer.compose(
            allItems,
            policy: titleSegmentation, places: placeGroups()))

        guard newSections.count == sections.count,
              zip(newSections, sections).allSatisfy({ new, old in
                  new.placeStopID == old.placeStopID && new.structure == old.structure
              }) else {
            sections = newSections
            return
        }

        for index in sections.indices {
            sections[index].placeName = newSections[index].placeName
            sections[index].placeHeading = newSections[index].placeHeading
            sections[index].placeHeadingPending = newSections[index].placeHeadingPending
            sections[index].placeCard = newSections[index].placeCard
        }
    }

    /// Total travel distance along the trajectory, in kilometers.
    var travelKilometers: Double { routeFacts().kilometers }

    private func routeDistanceKilometers(for locations: [CLLocation]) -> Double {
        guard locations.count >= 2 else { return 0 }
        var meters: CLLocationDistance = 0
        for i in 1..<locations.count {
            meters += locations[i].distance(from: locations[i - 1])
        }
        return meters / 1000
    }

    // MARK: Day insights (steps / weather / mood)

    /// Extras shown in the strip under the route map. Each entry is nil when
    /// its source has no data (or access was denied); the strip hides itself
    /// when everything is nil.
    struct DayInsights: Equatable {
        var steps: Int?
        var moodTitle: String?
        var weather: DayWeather?

        var isEmpty: Bool { steps == nil && moodTitle == nil && weather == nil }
    }

    private(set) var insights: DayInsights?
    @ObservationIgnored private var insightsTask: Task<Void, Never>?

    /// Where the day was mostly spent: the route stop with the longest dwell,
    /// measured from its first photo to the next stop's first photo (the last
    /// stop extends to its own last photo). Falls back to the first located
    /// photo when there is no route. Purely local — segments are already
    /// computed for the map, so this costs one array pass.
    private func dominantRouteCoordinate() -> CLLocationCoordinate2D? {
        let segments = routeSegments
        guard !segments.isEmpty else { return routeLocations.first?.coordinate }
        let timesByID = Dictionary(allItems.map { ($0.id, $0.creationDate) },
                                   uniquingKeysWith: { first, _ in first })
        func startTime(of segment: RouteSegment) -> Date {
            segment.itemIDs.lazy.compactMap { timesByID[$0] ?? nil }.min() ?? .distantPast
        }
        var best: RouteSegment = segments[0]
        var bestDwell: TimeInterval = -1
        for (index, segment) in segments.enumerated() {
            let start = startTime(of: segment)
            let end: Date
            if index + 1 < segments.count {
                end = startTime(of: segments[index + 1])
            } else {
                end = segment.itemIDs.lazy.compactMap { timesByID[$0] ?? nil }.max() ?? start
            }
            let dwell = end.timeIntervalSince(start)
            if dwell > bestDwell {
                bestDwell = dwell
                best = segment
            }
        }
        return best.coordinate
    }

    /// Loads the day's health/weather extras in parallel. Runs on its own
    /// lifetime so body-filter changes never cancel it; one load per model.
    func loadInsights() {
        guard showDayInsights, insightsTask == nil else { return }
        insightsTask = Task { [weak self] in
            guard let self else { return }
            defer { self.insightsTask = nil }
            let date = self.date
            let coordinate = self.dominantRouteCoordinate()
            async let steps = HealthService.shared.steps(on: date)
            async let mood = HealthService.shared.mood(on: date)
            let weather: DayWeather? = if let coordinate {
                await DayWeatherService.shared.weather(on: date, at: coordinate)
            } else {
                nil
            }
            guard !Task.isCancelled else { return }
            var next = DayInsights()
            next.steps = await steps
            next.moodTitle = (await mood)?.title
            next.weather = weather
            guard !next.isEmpty else { return }
            self.insights = next
        }
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
        }
    }

    func removeItems(ids: Set<String>) {
        guard allItemsUnfiltered.contains(where: { ids.contains($0.id) }) else { return }
        sourceRevision = UUID()
        allItemsUnfiltered.removeAll { ids.contains($0.id) }
        // A removed representative may have a previously suppressed copy.
        sharedVideoDuplicateIDs.removeAll()
        prepareSharedVideoDuplicates()
        pendingSourceItems?.removeAll { ids.contains($0.id) }
        allItems.removeAll { ids.contains($0.id) }
        if let manualCoverPhoto, ids.contains(manualCoverPhoto.id) {
            ManualCoverStore.shared.clear(for: date)
            self.manualCoverPhoto = nil
        }
        recomputeRouteDerived()
        favoriteIDs.subtract(ids)
        hiddenIDs.subtract(ids)
        invalidateEditorialPreparation()
        applySharedFilter(animated: true, force: true)
        scheduleReprepareAfterFilterChange()
    }

    private func remove(_ item: PhotoItem) {
        removeItems(ids: [item.id])
    }
}
