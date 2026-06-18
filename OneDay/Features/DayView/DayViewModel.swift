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

    /// Real trajectory: every located photo/video in chronological order.
    var routeLocations: [CLLocation] {
        allItems.compactMap(\.location)
    }

    /// Number of distinct places (coarsely rounded), used to decide if a map is worth showing.
    private var distinctPlaceCount: Int {
        var seen = Set<String>()
        for loc in routeLocations {
            seen.insert(String(format: "%.3f,%.3f", loc.coordinate.latitude, loc.coordinate.longitude))
        }
        return seen.count
    }

    var hasRoute: Bool { distinctPlaceCount >= 2 }

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
