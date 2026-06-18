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

    func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    func addToAlbum(named name: String, assets: [PHAsset]) async throws {
        let collection = try await albumCollection(named: name)
        try await add(assets, to: collection)
    }

    func addToAlbum(identifier: String, assets: [PHAsset]) async throws {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw NSError(domain: "OneDay", code: -2)
        }
        try await add(assets, to: collection)
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

    private func add(_ assets: [PHAsset], to collection: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else { return }
            request.addAssets(assets as NSArray)
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
