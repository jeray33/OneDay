import Photos
import UIKit
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
final class PhotoRotationService {
    static let shared = PhotoRotationService()
    private(set) var operations: [String: UUID] = [:]
    private(set) var unsupportedVersions: Set<String> = []
    private(set) var failures: [String: String] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var resourceEligibility: [String: Bool] = [:]
    private let journalKey = "OneDay.pendingPhotoContentEdits"

    private init() {}

    func canRotate(_ item: PhotoItem) -> Bool {
        guard !item.isForeignShared, item.asset.canPerform(.content),
              !unsupportedVersions.contains(item.asset.contentVersion) else { return false }
        if let cached = resourceEligibility[item.contentVersion] { return cached }
        let resources = PHAssetResource.assetResources(for: item.asset)
        let types = resources.compactMap { UTType($0.uniformTypeIdentifier) }
        let imageResources = resources.filter { [.photo, .fullSizePhoto, .alternatePhoto, .adjustmentBasePhoto].contains($0.type) }
        let eligible = PhotoRotationPolicy.allows(.init(
            isStillImage: item.asset.mediaType == .image && item.asset.playbackStyle == .image,
            isLivePhoto: item.isLivePhoto,
            isAnimated: types.contains { $0.conforms(to: .gif) },
            isRAW: types.contains { $0.conforms(to: .rawImage) },
            isHDR: item.asset.mediaSubtypes.contains(.photoHDR),
            isForeignShared: item.isForeignShared,
            systemAllowsContentEditing: item.asset.canPerform(.content),
            hasSupportedResources: !imageResources.isEmpty && imageResources.allSatisfy {
                guard let type = UTType($0.uniformTypeIdentifier) else { return false }
                return [UTType.jpeg, .png, .heic, .tiff].contains { type.conforms(to: $0) }
            }
        ))
        resourceEligibility[item.contentVersion] = eligible
        return eligible
    }

    func isSaving(_ id: String) -> Bool { operations[id] != nil }
    func takeFailure(for id: String) -> String? { failures.removeValue(forKey: id) }

    /// The service, not a gesture/view task, owns the write. Browsing away must
    /// not cancel an already-submitted Photos transaction.
    func start(_ item: PhotoItem, onSaved: @escaping (PHAsset) -> Void,
               onFailure: @escaping (Error) -> Void) {
        guard !isSaving(item.id), canRotate(item) else { return }
        let operation = UUID()
        failures[item.id] = nil
        operations[item.id] = operation
        tasks[item.id] = Task {
            let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "保存照片旋转") { [weak self] in
                Task { @MainActor in self?.tasks[item.id]?.cancel() }
            }
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
                if operations[item.id] == operation {
                    operations[item.id] = nil
                    tasks[item.id] = nil
                }
            }
            do {
                let saved = try await rotate(item)
                onSaved(saved)
            } catch {
                if let rotationError = error as? PhotoRotationError, rotationError == .unsupported {
                    unsupportedVersions.insert(item.asset.contentVersion)
                }
                let reportedError = error is CancellationError ? PhotoRotationError.interrupted : error
                failures[item.id] = reportedError.localizedDescription
                onFailure(reportedError)
            }
        }
    }

    /// A small persistent journal makes interrupted post-submit writes safe to
    /// reconcile on foreground / next launch. Refreshing an unmodified asset is
    /// harmless; replaying a rotation is not.
    func reconcilePendingEdits(onRefresh: (PHAsset) -> Void) {
        for id in pendingIDs where !isSaving(id) {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                onRefresh(asset)
            }
            removePending(id)
        }
    }

    private var pendingIDs: [String] { UserDefaults.standard.stringArray(forKey: journalKey) ?? [] }
    private func removePending(_ id: String) {
        UserDefaults.standard.set(pendingIDs.filter { $0 != id }, forKey: journalKey)
    }

    private func rotate(_ item: PhotoItem) async throws -> PHAsset {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotoRotationError.permission }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            throw PhotoRotationError.unavailable
        }
        guard asset.contentVersion == item.asset.contentVersion else { throw PhotoRotationError.changed }
        var freshItem = PhotoItem(asset: asset, sharedSource: item.sharedSource,
                                  isOwnSharedContribution: item.isOwnSharedContribution)
        freshItem.captureTimeZone = item.captureTimeZone
        guard canRotate(freshItem) else { throw PhotoRotationError.unsupported }

        let input = try await editingInput(for: asset)
        guard let url = input.fullSizeImageURL else { throw PhotoRotationError.unavailable }
        let output = PHContentEditingOutput(contentEditingInput: input)
        let previousAdjustment = input.adjustmentData.flatMap {
            PhotoRotationAdjustment.decode(formatIdentifier: $0.formatIdentifier,
                                           formatVersion: $0.formatVersion, data: $0.data)
        }
        // Known v2 recipes request their unadjusted base from Photos. Unknown
        // editors / legacy v1 request the current rendered appearance once,
        // retaining those edits as the new chain's starting point.
        let inputType = UTType(input.uniformTypeIdentifier ?? "")
        let preferred: UTType = inputType?.conforms(to: .png) == true ? .png
            : (inputType?.conforms(to: .heic) == true ? .heic : .jpeg)
        let type = output.supportedRenderedContentTypes.contains(preferred) ? preferred : .jpeg
        guard output.supportedRenderedContentTypes.contains(type) else { throw PhotoRotationError.unsupported }
        let outputURL = try output.renderedContentURL(for: type)
        let orientation = input.fullSizeImageOrientation
        let render = Task.detached(priority: .userInitiated) {
            try await PhotoRotationRenderWorker.shared.render(inputURL: url, outputURL: outputURL,
                                                              orientation: orientation, outputType: type.identifier,
                                                              previousAdjustment: previousAdjustment)
        }
        let adjustment = try await withTaskCancellationHandler {
            try await render.value
        } onCancel: { render.cancel() }
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw PhotoRotationError.interrupted }
        guard let latest = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject,
              latest.contentVersion == asset.contentVersion else { throw PhotoRotationError.changed }
        guard latest.canPerform(.content) else { throw PhotoRotationError.unsupported }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: PhotoRotationAdjustment.formatIdentifier,
            formatVersion: PhotoRotationAdjustment.formatVersion, data: try adjustment.encoded())
        UserDefaults.standard.set(Array(Set(pendingIDs + [item.id])), forKey: journalKey)
        do {
            // After submission do not check task cancellation. Photos owns the
            // transaction; always reconcile its actual completion.
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: latest).contentEditingOutput = output
            }
        } catch {
            removePending(item.id)
            throw error
        }
        guard let saved = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            throw PhotoRotationError.savedButUnavailable
        }
        removePending(item.id)
        return saved
    }

    private func editingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = {
            PhotoRotationAdjustment.decode(formatIdentifier: $0.formatIdentifier,
                                           formatVersion: $0.formatVersion, data: $0.data) != nil
        }
        let request = RotationEditingInputRequest(asset: asset)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(options: options, continuation: continuation)
            }
        } onCancel: { request.cancel() }
    }
}

/// PhotoKit can call back after cancellation, or cancellation can arrive before
/// it returns a request ID. Finish the continuation exactly once in both cases.
private nonisolated final class RotationEditingInputRequest: @unchecked Sendable {
    private let asset: PHAsset
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PHContentEditingInput, Error>?
    private var requestID: PHContentEditingInputRequestID?
    private var isCancelled = false

    init(asset: PHAsset) { self.asset = asset }

    func start(options: PHContentEditingInputRequestOptions,
               continuation: CheckedContinuation<PHContentEditingInput, Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let id = asset.requestContentEditingInput(with: options) { input, info in
            self.lock.lock()
            let callback = self.continuation
            self.continuation = nil
            self.lock.unlock()
            if let input { callback?.resume(returning: input) }
            else { callback?.resume(throwing: info[PHContentEditingInputErrorKey] as? Error ?? PhotoRotationError.unavailable) }
        }
        lock.lock()
        requestID = id
        let cancel = isCancelled
        lock.unlock()
        if cancel { asset.cancelContentEditingInputRequest(id) }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let callback = continuation
        continuation = nil
        let id = requestID
        lock.unlock()
        callback?.resume(throwing: CancellationError())
        if let id { asset.cancelContentEditingInputRequest(id) }
    }
}
