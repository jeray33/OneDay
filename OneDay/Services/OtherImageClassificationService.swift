import Photos
import ImageIO
import UniformTypeIdentifiers

/// Local-only, bounded background work. Unknown/cloud-only assets remain photos.
actor OtherImageClassificationService {
    static let shared = OtherImageClassificationService()

    private let store = ImageClassificationStore.shared
    private var libraryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastScanDate: Date?
    private var lastSelection: MediaCategorySelection?
    private var inFlight: Set<String> = []
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
                PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
                    assets.append(asset)
                }
                return assets
            }.value
            if !Task.isCancelled {
                let shared = await SharedAlbumCache.shared.current()
                var seen = Set(assets.map(\.localIdentifier))
                let sharedImages = shared.sharedAssets.filter {
                    $0.mediaType == .image && seen.insert($0.localIdentifier).inserted
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

    func classify(_ assets: [PHAsset]) async {
        let now = Date()
        var seen = Set<String>()
        let candidates = assets.filter { asset in
            let id = asset.localIdentifier
            guard seen.insert(id).inserted, !inFlight.contains(id),
                  MediaFilter.supportsImageClassification(asset),
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

        await withTaskGroup(of: (Int, ImageClassification).self) { group in
            func enqueue(_ index: Int) {
                let asset = candidates[index]
                group.addTask(priority: .utility) {
                    (index, await self.classifyWithLimit(asset))
                }
            }
            for _ in 0..<min(2, candidates.count) {
                enqueue(next)
                next += 1
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
                    enqueue(next)
                    next += 1
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
}
