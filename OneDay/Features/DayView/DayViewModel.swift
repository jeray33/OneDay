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
        if tunnelCoverPhoto?.id == id { tunnelCoverPhoto = replacement }
        sourceRevision = UUID()
        rebuildSections(animated: false)
    }

    private var favoriteIDs: Set<String>
    private var hiddenIDs: Set<String>
    var albumPickerItem: PhotoItem?

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
    /// Uses LazyVGrid in aligned mode, viewport-based image loading in waterfall
    /// mode. Turning this off keeps every photo view loaded in either layout.
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
    private(set) var tunnelCoverPhoto: PhotoItem?
    private var heroHue: (hue: CGFloat, saturation: CGFloat)?

    /// Nil while the sharpest still is still being ranked. Video-only days
    /// use their first video's still frame.
    var photoCoverItem: PhotoItem? {
        if let photo = tunnelCoverPhoto ?? coverPhotos.first { return photo }
        guard !editorialItems.contains(where: { !$0.isVideo }) else { return nil }
        return editorialItems.first
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
        let sortedItems = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
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
        let tabs = DayMediaTabs(items: sharedItems) { MediaFilter.category(for: $0.asset) }
        let selectedCategory = tabs.selection(preserving: nil)
        let composedItems = tabs.items(in: selectedCategory)
        let segmentation = TitleSegmentationPolicy()
        let composedSections = DaySectionComposer.compose(composedItems, policy: segmentation)
        self.titleSegmentation = segmentation
        self.allItemsUnfiltered = sortedItems
        self.allItems = composedItems
        self.includeSharedAlbums = savedShared
        self.mediaTabs = tabs
        self.selectedMediaCategory = selectedCategory
        self.sections = composedSections
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
        let newSections = DaySectionComposer.compose(
            allItems,
            policy: titleSegmentation, places: placeGroups())
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
            includeShared: includeSharedAlbums)
        mediaTabs = DayMediaTabs(items: sharedItems) { MediaFilter.category(for: $0.asset) }
        selectedMediaCategory = mediaTabs.selection(preserving: selectedMediaCategory)
        let filtered = mediaTabs.items(in: selectedMediaCategory)
        guard force || filtered.map(\.id) != allItems.map(\.id) else { return }
        filterPreparationID = UUID()
        bodyPreparationTask?.cancel()
        if filtered.isEmpty {
            brightColor = .white
        }
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

    /// Refreshes only body-derived colors, places, and captions.
    fileprivate func reprepareAfterFilterChange(generation: UUID) async {
        await computePageColor(generation: generation)
        guard filterPreparationID == generation else { return }
        await resolveSegmentPlaces(generation: generation)
        guard filterPreparationID == generation else { return }
        await resolvePlaces(generation: generation)
        guard filterPreparationID == generation else { return }
        await loadPhotoCaptions(generation: generation)
    }

    // MARK: Preparation (places, pastel color, and captions)

    func prepare() async {
        // This task has its own lifetime, so body-filter changes cannot abort it.
        Task { await prepareEditorial() }
        classifyDayImages()
        let generation = filterPreparationID
        guard isCurrentFilterPreparation(generation) else { return }
        await computePageColor(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        rebuildSections()
        await resolveSegmentPlaces(generation: generation)
        guard isCurrentFilterPreparation(generation) else { return }
        await resolvePlaces(generation: generation)
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
        await computeHeroHue(generation: generation)
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
        if let tunnelCoverPhoto, !sourceIDs.contains(tunnelCoverPhoto.id) {
            self.tunnelCoverPhoto = nil
        }
        Task { await prepareEditorial() }
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

    /// Keeps the existing hero-photo source for the immersive back cover.
    private func computeHeroHue(generation: UUID) async {
        guard let hero = coverPhotos.first ?? editorialItems.first,
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

    /// True when at least one located photo/video exists (map is worth showing).
    var hasAnyLocation: Bool { !routeLocations.isEmpty }

    /// Centroid coordinate of each route stop (one dot per stop on the map).
    var routeStopCoordinates: [CLLocationCoordinate2D] {
        routeSegments.map(\.coordinate)
    }

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
                                                   itemIDs: last.itemIDs + segment.itemIDs)
            } else {
                stops.append(RouteStop(id: segment.id, nameState: state,
                                       itemIDs: segment.itemIDs))
            }
        }
        return stops
    }

    /// Fully materialized stop names for the map banner:
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
        let newSections = DaySectionComposer.compose(
            allItems,
            policy: titleSegmentation, places: placeGroups())

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
        invalidateEditorialPreparation()
        applySharedFilter(animated: true, force: true)
        scheduleReprepareAfterFilterChange()
    }

    private func remove(_ item: PhotoItem) {
        removeItems(ids: [item.id])
    }
}
