import LinkPresentation
import Photos
import SwiftUI
import UIKit

struct PhotoShareSheet: View {
    let content: PreparedPhotoShare
    @Environment(\.dismiss) private var dismiss
    @State private var presentationDetent: PresentationDetent = .medium

    var body: some View {
        let dismiss = dismiss
        SystemShareView(controller: content.controller) { dismiss() }
            .ignoresSafeArea()
            .presentationDetents([.medium, .large], selection: $presentationDetent)
            .presentationDragIndicator(.visible)
    }
}

@MainActor
final class PreparedPhotoShare: Identifiable {
    let id = UUID()
    let controller: UIActivityViewController
    private let directory: URL

    private init(files: PhotoShareFiles, thumbnail: UIImage?) {
        directory = files.directory
        let sources = files.urls.map { PhotoShareItemSource(url: $0, thumbnail: thumbnail) }
        controller = UIActivityViewController(activityItems: sources, applicationActivities: nil)
        controller.loadViewIfNeeded()
    }

    static func prepare(asset: PHAsset) async throws -> PreparedPhotoShare {
        let files = try await PhotoShareFiles.prepare(asset: asset)
        do {
            let thumbnail = await ImageLoader.shared.thumbnail(
                asset: files.asset, size: CGSize(width: 320, height: 320),
                highQuality: true, contentMode: .aspectFit
            )
            try Task.checkCancellation()
            return PreparedPhotoShare(files: files, thumbnail: thumbnail)
        } catch {
            files.remove()
            throw error
        }
    }

    deinit {
        // Retain files for the entire share session, including activity extensions.
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SystemShareView: UIViewControllerRepresentable {
    let controller: UIActivityViewController
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let finish = onFinish
        controller.completionWithItemsHandler = { _, _, _, _ in finish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class PhotoShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let thumbnail: UIImage?
    private let metadata: LPLinkMetadata

    init(url: URL, thumbnail: UIImage?) {
        self.url = url
        self.thumbnail = thumbnail
        metadata = LPLinkMetadata()
        metadata.title = url.lastPathComponent
        if let thumbnail {
            let provider = NSItemProvider(object: thumbnail)
            metadata.imageProvider = provider
            metadata.iconProvider = provider
        }
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? {
        thumbnail
    }
}

private struct PhotoShareFiles {
    let directory: URL
    let urls: [URL]
    let asset: PHAsset

    static func prepare(asset: PHAsset) async throws -> Self {
        try Task.checkCancellation()
        guard let current = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.localIdentifier], options: nil
        ).firstObject else {
            throw PreparationError.unavailable
        }
        let resources = PHAssetResource.assetResources(for: current)
        let preferredTypes: [PHAssetResourceType]
        switch current.mediaType {
        case .image: preferredTypes = [.fullSizePhoto, .photo]
        case .video: preferredTypes = [.fullSizeVideo, .video]
        default: throw PreparationError.unavailable
        }
        guard let primary = preferredTypes.lazy.compactMap({ type in
            resources.first { $0.type == type }
        }).first else {
            throw PreparationError.unavailable
        }
        var selected = [primary]
        // Keep both Live Photo resources rather than silently flattening it.
        // The system share panel presents them as two files.
        if current.playbackStyle == .livePhoto {
            guard let paired = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else {
                throw PreparationError.unavailable
            }
            selected.append(paired)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneDay-Share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            for (index, resource) in selected.enumerated() {
                try Task.checkCancellation()
                // Separate resource folders also avoid duplicate original filenames.
                let folder = directory.appendingPathComponent("\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let filename = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
                let url = folder.appendingPathComponent(filename)
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                urls.append(url)
            }
            try Task.checkCancellation()
            return Self(directory: directory, urls: urls, asset: current)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private enum PreparationError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "无法读取这张照片或视频，请确认照片图库访问权限后重试。"
        }
    }
}
