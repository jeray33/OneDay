import Photos

/// Commands that can be performed on library assets.
/// Designed as an extension point: add new cases (tagging, hide, share...) over time.
enum LibraryAction {
    case toggleFavorite
    case delete
    case addToAlbum(named: String)
    case pickAlbum
}

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int

    static let hiddenAlbumID = "com.oneday.hidden-album"
    static let hiddenAlbum = AlbumInfo(id: hiddenAlbumID, title: "隐藏相簿", count: 0)
}

@MainActor
final class PhotoActionService {
    static let shared = PhotoActionService()
    private init() {}

    func setFavorite(_ favorite: Bool, on asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = favorite
        }
    }

    func setHidden(_ hidden: Bool, on asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isHidden = hidden
        }
    }

    func delete(_ assets: [PHAsset]) async throws {
        guard !assets.contains(where: { PhotoRotationService.shared.isSaving($0.localIdentifier) }) else {
            throw PhotoRotationError.busy
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func addToAlbum(named name: String, assets: [PHAsset]) async throws {
        let collection = try await albumCollection(named: name)
        try await add(assets, to: collection)
    }

    func addToAlbum(identifier: String, assets: [PHAsset]) async throws {
        guard let collection = collection(identifier: identifier) else {
            throw NSError(domain: "OneDay", code: -2)
        }
        try await add(assets, to: collection)
    }

    func removeFromAlbum(identifier: String, assets: [PHAsset]) async throws {
        guard let collection = collection(identifier: identifier) else {
            throw NSError(domain: "OneDay", code: -2)
        }
        try await remove(assets, from: collection)
    }

    /// Album ids among `albumIDs` that currently contain `asset`.
    /// Nonisolated: PhotoKit fetches are thread-safe, and the preview pages
    /// query membership off the main thread.
    nonisolated func albumIDs(containing asset: PHAsset, among albumIDs: [String]) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var result = Set<String>()
        for id in albumIDs {
            guard !Task.isCancelled else { return result }
            guard let collection = collection(identifier: id) else { continue }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "localIdentifier == %@", asset.localIdentifier)
            options.fetchLimit = 1
            if PHAsset.fetchAssets(in: collection, options: options).count > 0 {
                result.insert(id)
            }
        }
        return result
    }

    /// Creates an empty user album (or returns the existing one with the same title).
    @discardableResult
    func createAlbum(named name: String) async throws -> AlbumInfo {
        let collection = try await albumCollection(named: name)
        let count = PHAsset.fetchAssets(in: collection, options: nil).count
        return AlbumInfo(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? name,
            count: count
        )
    }

    /// User-created albums only (regular albums), with asset counts.
    func userAlbums() -> [AlbumInfo] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        var albums: [AlbumInfo] = []
        collections.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle ?? "未命名相簿"
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append(AlbumInfo(id: collection.localIdentifier, title: title, count: count))
        }
        return albums.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private nonisolated func collection(identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject
    }

    private func add(_ assets: [PHAsset], to collection: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.addAssets(assets as NSArray)
        }
    }

    private func remove(_ assets: [PHAsset], from collection: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.removeAssets(assets as NSArray)
        }
    }

    private func albumCollection(named name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if let found = existing.firstObject { return found }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholder = request.placeholderForCreatedAssetCollection
        }
        guard let identifier = placeholder?.localIdentifier,
              let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            throw NSError(domain: "OneDay", code: -1)
        }
        return collection
    }
}
