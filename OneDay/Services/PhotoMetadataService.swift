import Photos
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CoreLocation
import CoreGraphics
import Foundation

struct PhotoMetadataSnapshot: Sendable {
    struct Section: Sendable, Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    struct Row: Sendable, Identifiable {
        let id: String
        let key: String
        let value: String
    }

    let sections: [Section]
}

actor PhotoMetadataService {
    static let shared = PhotoMetadataService()
    /// Whole-snapshot cache, kept for the process lifetime: the snapshot only
    /// carries raw asset/file data, never reverse-geocode results (those live
    /// in `LocationResolver`, where failures are never cached long-term).
    private var cache: [String: PhotoMetadataSnapshot] = [:]

    func metadata(for asset: PHAsset) async -> PhotoMetadataSnapshot {
        if let cached = cache[asset.localIdentifier] {
            return cached
        }

        var sections: [PhotoMetadataSnapshot.Section] = []
        sections.append(assetSection(for: asset))
        sections.append(resourceSection(for: asset))

        if let url = await originalURL(for: asset) {
            sections.append(contentsOf: await fileSections(for: asset, url: url))
        } else {
            sections.append(
                PhotoMetadataSnapshot.Section(
                    id: "file-unavailable",
                    title: "文件信息",
                    rows: [
                        PhotoMetadataSnapshot.Row(
                            id: "file-unavailable-row",
                            key: "状态",
                            value: "原始文件未就绪（可能在 iCloud 中，或系统未返回可读 URL）"
                        )
                    ]
                )
            )
        }

        let snapshot = PhotoMetadataSnapshot(sections: sections)
        cache[asset.localIdentifier] = snapshot
        return snapshot
    }

    private func assetSection(for asset: PHAsset) -> PhotoMetadataSnapshot.Section {
        var rows: [PhotoMetadataSnapshot.Row] = []
        rows.append(row("localIdentifier", asset.localIdentifier))
        rows.append(row("mediaType", mediaTypeText(asset.mediaType)))
        rows.append(row("mediaSubtypes", mediaSubtypeText(asset.mediaSubtypes)))
        rows.append(row("pixelWidth", "\(asset.pixelWidth)"))
        rows.append(row("pixelHeight", "\(asset.pixelHeight)"))
        rows.append(
            row(
                "aspectRatio",
                String(format: "%.4f", max(0.0001, CGFloat(asset.pixelWidth) / max(1, CGFloat(asset.pixelHeight))))
            )
        )
        rows.append(row("duration", String(format: "%.3f s", asset.duration)))
        rows.append(row("isFavorite", asset.isFavorite ? "true" : "false"))
        rows.append(row("isHidden", asset.isHidden ? "true" : "false"))
        rows.append(row("isBurst", asset.representsBurst ? "true" : "false"))
        rows.append(row("burstIdentifier", asset.burstIdentifier ?? "—"))
        rows.append(row("sourceType", sourceTypeText(asset.sourceType)))
        if let date = asset.creationDate {
            rows.append(row("creationDate", iso8601(date)))
        }
        if let date = asset.modificationDate {
            rows.append(row("modificationDate", iso8601(date)))
        }
        if let location = asset.location {
            rows.append(contentsOf: locationRows(location))
        }
        return .init(id: "asset", title: "资产信息", rows: rows)
    }

    private func resourceSection(for asset: PHAsset) -> PhotoMetadataSnapshot.Section {
        let resources = PHAssetResource.assetResources(for: asset)
        var rows: [PhotoMetadataSnapshot.Row] = []
        for (index, resource) in resources.enumerated() {
            let prefix = "resource[\(index)]"
            rows.append(row("\(prefix).type", "\(resource.type.rawValue)"))
            rows.append(row("\(prefix).originalFilename", resource.originalFilename))
            if #available(iOS 14.0, *) {
                rows.append(row("\(prefix).uti", resource.uniformTypeIdentifier))
            }
            if let size = resource.value(forKey: "fileSize") as? CLong {
                rows.append(row("\(prefix).fileSize", byteCountString(Int64(size))))
            }
        }
        if rows.isEmpty {
            rows.append(row("resources", "—"))
        }
        return .init(id: "resources", title: "资源信息", rows: rows)
    }

    private func fileSections(for asset: PHAsset, url: URL) async -> [PhotoMetadataSnapshot.Section] {
        var sections: [PhotoMetadataSnapshot.Section] = []
        sections.append(
            .init(
                id: "file-basic",
                title: "文件信息",
                rows: [
                    row("url", url.absoluteString),
                    row("pathExtension", url.pathExtension.isEmpty ? "—" : url.pathExtension)
                ]
            )
        )

        if asset.mediaType == .image {
            if let imageSection = imageMetadataSection(url: url) {
                sections.append(imageSection)
            }
        } else if asset.mediaType == .video {
            sections.append(contentsOf: await videoMetadataSections(url: url))
        }

        return sections
    }

    private func imageMetadataSection(url: URL) -> PhotoMetadataSnapshot.Section? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        let flattened = flattenDictionary(props, prefix: nil)
        let rows = flattened
            .sorted { $0.key < $1.key }
            .map { row($0.key, $0.value) }
        return .init(id: "image-raw", title: "图像元数据（EXIF/TIFF/GPS/IPTC）", rows: rows)
    }

    private func videoMetadataSections(url: URL) async -> [PhotoMetadataSnapshot.Section] {
        let asset = AVURLAsset(url: url)
        var sections: [PhotoMetadataSnapshot.Section] = []
        let duration = try? await asset.load(.duration)
        let tracks = try? await asset.load(.tracks)

        var basics: [PhotoMetadataSnapshot.Row] = []
        if let duration {
            basics.append(row("duration", String(format: "%.3f s", CMTimeGetSeconds(duration))))
        }
        if let tracks {
            basics.append(row("trackCount", "\(tracks.count)"))
            for (index, track) in tracks.enumerated() {
                let size = try? await track.load(.naturalSize)
                let fps = try? await track.load(.nominalFrameRate)
                let bitrate = try? await track.load(.estimatedDataRate)
                let formatDescriptions = try? await track.load(.formatDescriptions)
                basics.append(row("track[\(index)].mediaType", track.mediaType.rawValue))
                if let size {
                    basics.append(row("track[\(index)].size", "\(Int(size.width))x\(Int(size.height))"))
                }
                if let fps {
                    basics.append(row("track[\(index)].fps", String(format: "%.3f", fps)))
                }
                if let bitrate {
                    basics.append(row("track[\(index)].estimatedDataRate", String(format: "%.0f bps", bitrate)))
                }
                if let formatDescriptions, let first = formatDescriptions.first {
                    let fourCC = CMFormatDescriptionGetMediaSubType(first)
                    basics.append(row("track[\(index)].codec", fourCCString(fourCC)))
                }
            }
        }
        sections.append(.init(id: "video-basic", title: "视频元数据", rows: basics.isEmpty ? [row("status", "无可用视频元数据")] : basics))

        var commonRows: [PhotoMetadataSnapshot.Row] = []
        let commonMetadata = try? await asset.load(.commonMetadata)
        for item in commonMetadata ?? [] {
            commonRows.append(
                row(
                    item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "common",
                    await metadataItemValue(item)
                )
            )
        }
        if !commonRows.isEmpty {
            sections.append(.init(id: "video-common", title: "视频公共元数据", rows: commonRows))
        }

        let formatIDs = try? await asset.load(.availableMetadataFormats)
        if let formatIDs {
            var rawRows: [PhotoMetadataSnapshot.Row] = []
            for format in formatIDs {
                let items = try? await asset.loadMetadata(for: format)
                for item in items ?? [] {
                    let keyPart = item.key.flatMap { "\($0)" } ?? "key"
                    rawRows.append(row("\(format.rawValue).\(keyPart)", await metadataItemValue(item)))
                }
            }
            if !rawRows.isEmpty {
                sections.append(.init(id: "video-raw", title: "视频原始元数据", rows: rawRows))
            }
        }
        return sections
    }

    private func originalURL(for asset: PHAsset) async -> URL? {
        await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                continuation.resume(returning: input?.fullSizeImageURL ?? input?.audiovisualAsset.flatMap { ($0 as? AVURLAsset)?.url })
            }
        }
    }


    private func locationRows(_ location: CLLocation) -> [PhotoMetadataSnapshot.Row] {
        var rows: [PhotoMetadataSnapshot.Row] = []
        rows.append(row("location.latitude", String(format: "%.8f", location.coordinate.latitude)))
        rows.append(row("location.longitude", String(format: "%.8f", location.coordinate.longitude)))
        rows.append(row("location.altitude", String(format: "%.2f m", location.altitude)))
        rows.append(row("location.horizontalAccuracy", String(format: "%.2f m", location.horizontalAccuracy)))
        rows.append(row("location.verticalAccuracy", String(format: "%.2f m", location.verticalAccuracy)))
        if location.speed >= 0 {
            rows.append(row("location.speed", String(format: "%.2f m/s", location.speed)))
        }
        if location.course >= 0 {
            rows.append(row("location.course", String(format: "%.2f°", location.course)))
        }
        rows.append(row("location.timestamp", iso8601(location.timestamp)))
        return rows
    }

    private func row(_ key: String, _ value: String) -> PhotoMetadataSnapshot.Row {
        .init(id: "\(key)-\(value)", key: key, value: value)
    }

    private func mediaTypeText(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }

    private func mediaSubtypeText(_ subtype: PHAssetMediaSubtype) -> String {
        var values: [String] = []
        if subtype.contains(.photoPanorama) { values.append("photoPanorama") }
        if subtype.contains(.photoHDR) { values.append("photoHDR") }
        if subtype.contains(.photoLive) { values.append("photoLive") }
        if subtype.contains(.photoDepthEffect) { values.append("photoDepthEffect") }
        if subtype.contains(.videoStreamed) { values.append("videoStreamed") }
        if subtype.contains(.videoHighFrameRate) { values.append("videoHighFrameRate") }
        if subtype.contains(.videoTimelapse) { values.append("videoTimelapse") }
        if values.isEmpty { values.append("none") }
        return values.joined(separator: ", ")
    }

    private func sourceTypeText(_ sourceType: PHAssetSourceType) -> String {
        var values: [String] = []
        if sourceType.contains(.typeUserLibrary) { values.append("userLibrary") }
        if sourceType.contains(.typeCloudShared) { values.append("cloudShared") }
        if sourceType.contains(.typeiTunesSynced) { values.append("iTunesSynced") }
        if values.isEmpty { values.append("unknown") }
        return values.joined(separator: ", ")
    }

    private func flattenDictionary(_ dict: [String: Any], prefix: String?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in dict {
            let fullKey = prefix.map { "\($0).\(key)" } ?? key
            if let nested = value as? [String: Any] {
                let nestedFlat = flattenDictionary(nested, prefix: fullKey)
                for (k, v) in nestedFlat {
                    out[k] = v
                }
            } else if let arr = value as? [Any] {
                out[fullKey] = arr.map { stringifyAny($0) }.joined(separator: ", ")
            } else {
                out[fullKey] = stringifyAny(value)
            }
        }
        return out
    }

    private func stringifyAny(_ value: Any) -> String {
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let date = value as? Date {
            return iso8601(date)
        }
        if let str = value as? String {
            return str
        }
        return "\(value)"
    }

    private func metadataItemValue(_ item: AVMetadataItem) async -> String {
        if let string = try? await item.load(.stringValue), !string.isEmpty {
            return string
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return iso8601(date)
        }
        if let data = try? await item.load(.dataValue) {
            return "binary(\(data.count) bytes)"
        }
        return "—"
    }

    private func fourCCString(_ code: FourCharCode) -> String {
        let chars: [CChar] = [
            CChar((code >> 24) & 255),
            CChar((code >> 16) & 255),
            CChar((code >> 8) & 255),
            CChar(code & 255),
            0
        ]
        return String(cString: chars)
    }

    private func byteCountString(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
