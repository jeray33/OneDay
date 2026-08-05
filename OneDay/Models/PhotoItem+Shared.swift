import Photos
import Foundation

extension PhotoItem {
    /// `true` for photos that belong to the user's iCloud Shared Photo Library
    /// but were contributed by another participant (e.g. family member). Uses
    /// `PHAsset.sourceType` because the public Photos framework does not
    /// expose a per-contributor identifier for Shared Photo Library assets.
    ///
    /// Heuristic:
    /// - `.typeCloudShared` flag is set whenever the asset lives in a Shared Photo
    ///   Library.
    /// - `.typeUserLibrary` flag is set for assets the user has personally taken
    ///   or imported into their own library (including ones migrated into the
    ///   Shared Library with the user's own history).
    /// - Photos contributed by *other* members of the Shared Library have only
    ///   the `.typeCloudShared` bit and no `.typeUserLibrary` bit. That combination
    ///   is the most reliable approximation of "non-self photos from the
    ///   Shared Photo Library" available through the public API.
    static func isSharedLibraryOrigin(_ asset: PHAsset) -> Bool {
        let st = asset.sourceType
        return st.contains(.typeCloudShared) && !st.contains(.typeUserLibrary)
    }
}

extension PhotoItem {
    /// Builds a `PhotoItem` from a `PHAsset` with the shared-library flag
    /// resolved at construction time. All call sites must use this factory
    /// instead of any raw `(asset:)` initializer so the flag is never silently
    /// left as `false`.
    ///
    /// `sharedIDs` is the set of asset `localIdentifier`s that live in any
    /// `.albumCloudShared` collection (subscriptions or owned shared albums),
    /// produced by `PhotoLibraryService.sharedCloudAssetIDs()`. A photo is
    /// considered "shared from another contributor" when **either**:
    /// - Its `sourceType` matches `isSharedLibraryOrigin(_:)` (covers the iOS
    ///   16+ Shared Photo Library), or
    /// - It is a member of any iCloud Shared Album (covers the older "shared
    ///   album" feature where subscribed photos also have `.typeUserLibrary`).
    static func build(from asset: PHAsset, sharedIDs: Set<String> = []) -> PhotoItem {
        let inSharedAlbum = sharedIDs.contains(asset.localIdentifier)
        let inSharedLibrary = isSharedLibraryOrigin(asset)
        return PhotoItem(
            asset: asset,
            isFromSharedLibrary: inSharedAlbum || inSharedLibrary
        )
    }

    /// Bulk variant: prefer over `map { PhotoItem.build(from: $0, sharedIDs:) }`
    /// to keep the call site compact and the shared detection in one place.
    static func build(from assets: [PHAsset], sharedIDs: Set<String> = []) -> [PhotoItem] {
        assets.map { build(from: $0, sharedIDs: sharedIDs) }
    }
}
