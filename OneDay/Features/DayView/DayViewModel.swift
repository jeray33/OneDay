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
    private static let backgroundKey = "OneDay.pageBackground"

    var background: PageBackground {
        didSet { UserDefaults.standard.set(background.rawValue, forKey: Self.backgroundKey) }
    }
    private(set) var warmColor: Color = Color(red: 0.93, green: 0.78, blue: 0.62)
    private(set) var dominantColor: Color = Color(white: 0.5)
    private var dominantIsDark = false

    var pageBackgroundColor: Color {
        switch background {
        case .paper: return Color(white: 0.96)
        case .dark: return Color(white: 0.07)
        case .warm: return warmColor
        case .dominant: return dominantColor
        }
    }

    var pageColorScheme: ColorScheme {
        switch background {
        case .dark: return .dark
        case .dominant: return dominantIsDark ? .dark : .light
        default: return .light
        }
    }

    init(date: Date, items: [PhotoItem]) {
        self.date = date
        self.allItems = items.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        self.sections = MagazineLayoutEngine.compose(items)
        self.favoriteIDs = Set(items.filter { $0.isFavorite }.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Self.backgroundKey)
        self.background = PageBackground(rawValue: saved ?? "") ?? .paper
    }

    var photoCount: Int { allItems.filter { !$0.isVideo }.count }
    var videoCount: Int { allItems.filter(\.isVideo).count }

    // MARK: Preparation (Vision similarity + places + warm color)

    func prepare() async {
        await computeWarmColor()
        await applyVisionGrouping()
        await resolvePlaces()
        await resolveSegmentNames()
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

        // Dominant: the photo's own color, lightly toned for use as a full-page background.
        let dominant = UIColor(hue: h,
                               saturation: min(s, 0.6),
                               brightness: max(min(b, 0.92), 0.18), alpha: 1)
        let isDark = min(b, 0.92) < 0.5

        withAnimation(.easeInOut(duration: 0.3)) {
            warmColor = Color(uiColor: warm)
            dominantColor = Color(uiColor: dominant)
            dominantIsDark = isDark
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

        let newSections = MagazineLayoutEngine.compose(allItems, similar: similar)
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
