import Photos
import SwiftUI
import UIKit

struct PhotoShareSheet: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var files: PhotoShareFiles?
    @State private var errorMessage: String?
    @State private var preparationID = UUID()
    @State private var presentationDetent: PresentationDetent = .medium

    var body: some View {
        ZStack {
            if let files {
                SystemShareView(urls: files.urls) { dismiss() }
                    .ignoresSafeArea()
            } else {
                NavigationStack {
                    Group {
                        if let errorMessage {
                            ContentUnavailableView {
                                Label("无法共享", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(errorMessage)
                            } actions: {
                                Button("重试") { preparationID = UUID() }
                            }
                        } else {
                            ProgressView("正在准备共享…")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $presentationDetent)
        .presentationDragIndicator(.visible)
        .task(id: preparationID) {
            errorMessage = nil
            do {
                let prepared = try await PhotoShareFiles.prepare(asset: asset)
                guard !Task.isCancelled else {
                    prepared.remove()
                    return
                }
                files = prepared
            } catch is CancellationError {
                // Dismissing while iCloud downloads must not present an error.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            files?.remove()
        }
    }
}

private struct SystemShareView: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct PhotoShareFiles {
    let directory: URL
    let urls: [URL]

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
            return Self(directory: directory, urls: urls)
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
