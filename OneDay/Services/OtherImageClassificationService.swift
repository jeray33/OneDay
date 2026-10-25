import Photos
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Local-only, bounded background work. Unknown/cloud-only assets remain photos.
actor OtherImageClassificationService {
    static let shared = OtherImageClassificationService()

    private let store = ImageClassificationStore.shared
    private var libraryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastScanDate: Date?
    private var lastSelection: MediaCategorySelection?
    private var inFlight: Set<String> = []
    private var priorityAssetIDs: Set<String> = []
    private var priorityRevision = 0
    private var failures: [String: (date: Date, modificationDate: Date?)] = [:]
    private var activeReaders = 0
    private var readerWaiters: [CheckedContinuation<Void, Never>] = []

    func indexIfNeeded(matching selection: MediaCategorySelection) {
        lastSelection = selection
        guard selection.needsImageClassification, libraryTask == nil else { return }
        // Avoid rescheduling a library scan from each date/history refresh.
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < 60 { return }
        libraryTask = Task(priority: .utility) {
            let assets = await Task.detached(priority: .utility) {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard status == .authorized || status == .limited else { return [PHAsset]() }
                var assets: [PHAsset] = []
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                for type in [PHAssetMediaType.image, .video] {
                    PHAsset.fetchAssets(with: type, options: options).enumerateObjects { asset, _, _ in
                        assets.append(asset)
                    }
                }
                return assets
            }.value
            if !Task.isCancelled {
                let shared = await SharedAlbumCache.shared.current()
                var seen = Set(assets.map(\.localIdentifier))
                let sharedImages = shared.sharedAssets.filter {
                    MediaFilter.isEligible($0) && seen.insert($0.localIdentifier).inserted
                }
                await classify(assets + sharedImages)
            }
            if !Task.isCancelled { lastScanDate = Date() }
            libraryTask = nil
        }
    }

    func libraryDidChange() {
        store.libraryDidChange()
        failures.removeAll()
        lastScanDate = nil
        libraryTask?.cancel()
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            if let libraryTask { await libraryTask.value }
            guard !Task.isCancelled, let selection = lastSelection else { return }
            indexIfNeeded(matching: selection)
        }
    }

    /// Prioritize this day in an already-running library batch, or classify only
    /// these assets if no batch owns them. Never starts a whole-library scan.
    func classifyCurrentDay(_ assets: [PHAsset]) async {
        priorityAssetIDs = Set(assets.map(\.localIdentifier))
        priorityRevision += 1
        if let libraryTask, libraryTask.isCancelled { await libraryTask.value }
        guard !Task.isCancelled else { return }
        await classify(assets)
    }

    func classify(_ assets: [PHAsset]) async {
        guard !Task.isCancelled else { return }
        let repairGeneration = store.currentGeneration
        var repaired = false
        for asset in assets where MediaFilter.isSharedVideo(asset) {
            if store.repairSharedVideoClassification(
                for: asset.localIdentifier, modificationDate: asset.modificationDate,
                generation: repairGeneration
            ) { repaired = true }
        }
        if repaired {
            await store.persist()
            ImageClassificationStore.notify(changed: true, finished: !store.isIndexing)
        }
        let now = Date()
        var seen = Set<String>()
        var candidates = assets.filter { asset in
            let id = asset.localIdentifier
            guard seen.insert(id).inserted, !inFlight.contains(id),
                  MediaFilter.needsAutomaticClassification(asset),
                  store.override(for: id) == .automatic,
                  store.classification(for: id, modificationDate: asset.modificationDate) == .unknown
            else { return false }
            if let failure = failures[id],
               failure.modificationDate == asset.modificationDate,
               now.timeIntervalSince(failure.date) < 60 { return false }
            return true
        }
        guard !candidates.isEmpty, !Task.isCancelled else { return }
        let generation = store.currentGeneration
        inFlight.formUnion(candidates.map(\.localIdentifier))
        store.beginWork()
        ImageClassificationStore.notify(changed: false, finished: false)
        var changedSinceNotification = false
        var lastNotification = Date()
        var next = 0
        var queuedPriorityRevision = -1

        await withTaskGroup(of: (Int, ImageClassification).self) { group in
            func enqueueNext() {
                // Only reorder work not yet submitted. Completed/in-flight
                // indices must continue referring to the same immutable asset.
                if queuedPriorityRevision != priorityRevision {
                    let remaining = candidates[next...]
                    let priorityIDs = priorityAssetIDs
                    let priority = remaining.filter { priorityIDs.contains($0.localIdentifier) }
                    let other = remaining.filter { !priorityIDs.contains($0.localIdentifier) }
                    candidates.replaceSubrange(next..., with: priority + other)
                    queuedPriorityRevision = priorityRevision
                }
                let index = next
                let asset = candidates[index]
                next += 1
                group.addTask(priority: .utility) {
                    (index, await self.classifyWithLimit(asset))
                }
            }
            for _ in 0..<min(2, candidates.count) {
                enqueueNext()
            }
            for await (index, result) in group {
                let asset = candidates[index]
                let id = asset.localIdentifier
                inFlight.remove(id)
                guard !Task.isCancelled, generation == store.currentGeneration else {
                    group.cancelAll()
                    continue
                }
                if result == .unknown {
                    failures[id] = (Date(), asset.modificationDate)
                } else {
                    failures[id] = nil
                }
                let changed = store.record(
                    result, for: id, modificationDate: asset.modificationDate, generation: generation
                )
                changedSinceNotification = changedSinceNotification || changed
                // Coalesce body updates; the tunnel refreshes only at completion.
                if changedSinceNotification, Date().timeIntervalSince(lastNotification) >= 2 {
                    ImageClassificationStore.notify(changed: true, finished: false)
                    changedSinceNotification = false
                    lastNotification = Date()
                }
                if next < candidates.count {
                    enqueueNext()
                }
            }
        }
        inFlight.subtract(candidates.map(\.localIdentifier))
        store.endWork()
        await store.persist()
        ImageClassificationStore.notify(changed: changedSinceNotification, finished: !store.isIndexing)
    }

    private func classifyWithLimit(_ asset: PHAsset) async -> ImageClassification {
        if activeReaders >= 2 {
            await withCheckedContinuation { readerWaiters.append($0) }
        } else {
            activeReaders += 1
        }
        defer {
            if readerWaiters.isEmpty {
                activeReaders -= 1
            } else {
                readerWaiters.removeFirst().resume()
            }
        }
        return await Self.classifyLocalAsset(asset)
    }

    nonisolated private static func classifyLocalAsset(_ asset: PHAsset) async -> ImageClassification {
        guard !Task.isCancelled else { return .unknown }
        if asset.representsBurst || MediaFilter.hasPhotoSubtype(asset.mediaSubtypes) { return .photo }
        if asset.mediaType == .video { return await classifyVideo(asset) }
        let resources = PHAssetResource.assetResources(for: asset)
        if resources.contains(where: { resource in
            MediaFilter.isPhotoResourceType(resource.uniformTypeIdentifier)
        }) { return .photo }

        let url: URL? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            // Read the original plus adjustment data, not a flattened edited export.
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL)
            }
        }
        guard !Task.isCancelled, let url,
              let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
              )
        else { return .unknown }
        if CGImageSourceGetCount(source) > 1, let identifier = CGImageSourceGetType(source),
           let type = UTType(identifier as String),
           type.conforms(to: .png) || type.conforms(to: .webP) {
            return .photo
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return CameraMetadataClassifier.classify(properties: properties)
    }

    /// Videos have no EXIF; camera footage is recognized by the recording
    /// device make/model in the QuickTime container metadata. Unreadable or
    /// cloud-only assets stay unknown so they are never demoted by a guess.
    nonisolated private static func classifyVideo(_ asset: PHAsset) async -> ImageClassification {
        if MediaFilter.isSharedVideo(asset) { return .photo }
        if MediaFilter.hasCameraVideoSubtype(asset.mediaSubtypes) { return .photo }
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = false
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input)
            }
        }
        guard !Task.isCancelled, let avAsset = input?.audiovisualAsset,
              let metadata = try? await avAsset.load(.metadata)
        else { return .unknown }
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(
                from: metadata, withKey: key.rawValue, keySpace: nil
            ).first else { return nil }
            return try? await item.load(.stringValue)
        }
        return await CameraMetadataClassifier.classifyVideo(
            make: value(.quickTimeMetadataKeyMake),
            model: value(.quickTimeMetadataKeyModel)
        )
    }
}
