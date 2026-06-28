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

    var background: PageBackground {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: Self.backgroundKey) }
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
    private var photoFrameColors: [String: Color] = [:]
    private(set) var warmColor: Color    = Color(red: 0.93, green: 0.78, blue: 0.62)
    private(set) var dominantColor: Color = Color(white: 0.5)
    private(set) var vibrantColor: Color  = Color(white: 0.5)
    private var dominantIsDark = false
    private var vibrantIsDark  = false

    var pageBackgroundColor: Color {
        switch background {
        case .paper:    return Color(white: 0.96)
        case .dark:     return Color(white: 0.07)
        case .warm:     return warmColor
        case .dominant: return dominantColor
        case .vibrant:  return vibrantColor
        }
    }

    var pageColorScheme: ColorScheme {
        switch background {
        case .dark:     return .dark
        case .dominant: return dominantIsDark ? .dark : .light
        case .vibrant:  return vibrantIsDark  ? .dark : .light
        default:        return .light
        }
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

    /// Recomputes sections using the current enabledTemplates (no Vision grouping).
    private func recompose() {
        let newSections = MagazineLayoutEngine.compose(allItems, enabled: enabledTemplates)
        withAnimation(.easeInOut(duration: 0.35)) { sections = newSections }
    }

    /// Returns the frame color for a photo based on the current border style.
    func frameColor(for item: PhotoItem) -> Color {
        switch borderStyle {
        case .white:   return Theme.frame
        case .black:   return .black
        case .colored: return photoFrameColors[item.id] ?? Theme.frame
        }
    }

    // MARK: Preparation (Vision similarity + places + warm color)

    func prepare() async {
        await computeWarmColor()
        await applyVisionGrouping()
        await resolvePlaces()
        await resolveSegmentNames()
        if borderStyle == .colored { await computeFrameColors() }
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

        withAnimation(.easeInOut(duration: 0.3)) {
            warmColor     = Color(uiColor: warm)
            dominantColor = Color(uiColor: dominant)
            vibrantColor  = Color(uiColor: vibrant)
            dominantIsDark = isDark
            vibrantIsDark  = vIsDark
        }
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

        let similar: (PhotoItem, PhotoItem) -> Bool = { a, b in
            // Time proximity gate so look-alike but unrelated scenes aren't merged.
            let gap = abs((a.creationDate ?? .distantPast)
                .timeIntervalSince(b.creationDate ?? .distantPast))
            guard gap <= 8 * 60 else { return false }
            if let d = distances["\(a.id)|\(b.id)"] { return d < 0.62 }
            return false
        }

        let newSections = MagazineLayoutEngine.compose(allItems, similar: similar, enabled: enabledTemplates)
        withAnimation(.easeInOut(duration: 0.4)) { sections = newSections }
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
