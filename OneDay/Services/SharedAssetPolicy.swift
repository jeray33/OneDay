/// Which mutating operations the app allows on one library item, resolved
/// from its shared provenance and the system's own capability report.
///
/// Two layers of protection:
/// - Items someone else shared (an iCloud Shared Album photo a friend posted,
///   or another member's Shared Photo Library contribution) are read-only
///   in-app. They are not the user's to delete, hide, re-file, favorite or
///   re-caption — even where the system might technically allow it, because
///   Shared Photo Library participants can edit each other's photos but
///   OneDay refuses on the owner's behalf. Classification stays available:
///   it is app-local bookkeeping and the only way to fix, say, a screenshot a
///   friend sent that landed in the wrong media tab.
/// - Everything else follows `PHAsset.canPerform`, so items the system itself
///   refuses (e.g. an album the user merely subscribes to) are never even
///   attempted.
struct SharedAssetPolicy: Equatable {
    struct Input: Equatable {
        /// The item was shared by someone else, not the user's own upload.
        var isForeignShared: Bool
        /// The system allows deleting the item (`PHAsset.canPerform(.delete)`).
        var systemAllowsDelete: Bool
        /// The system allows property edits (`PHAsset.canPerform(.properties)`).
        var systemAllowsEditProperties: Bool
    }

    var canDelete: Bool
    var canHide: Bool
    var canEditAlbums: Bool
    var canFavorite: Bool
    var canEditCaption: Bool
    var canClassify: Bool

    /// Read-only profile for items someone else shared: only classification
    /// (app-local) remains available.
    static let foreignShared = SharedAssetPolicy(
        canDelete: false, canHide: false, canEditAlbums: false,
        canFavorite: false, canEditCaption: false, canClassify: true)

    /// Fully permissive profile, used when there is no concrete item.
    static let unrestricted = SharedAssetPolicy(
        canDelete: true, canHide: true, canEditAlbums: true,
        canFavorite: true, canEditCaption: true, canClassify: true)

    static func resolve(_ input: Input) -> SharedAssetPolicy {
        if input.isForeignShared { return .foreignShared }
        return SharedAssetPolicy(
            canDelete: input.systemAllowsDelete,
            canHide: input.systemAllowsEditProperties,
            canEditAlbums: input.systemAllowsEditProperties,
            canFavorite: input.systemAllowsEditProperties,
            canEditCaption: input.systemAllowsEditProperties,
            canClassify: true)
    }
}
