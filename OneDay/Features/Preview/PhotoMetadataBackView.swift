import SwiftUI

struct PhotoMetadataBackView: View {
    let snapshot: PhotoMetadataSnapshot?
    let isLoading: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white)

            content
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.black.opacity(0.75))
                Text("读取照片信息…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.black.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    cameraRow(snapshot)
                    paramsRow(snapshot)
                    detailList(snapshot)
                    locationList(snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("无可用照片信息")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    private func cameraRow(_ snapshot: PhotoMetadataSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("设备")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black.opacity(0.7))
            Spacer(minLength: 10)
            Text(extractCameraModel(from: snapshot))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black.opacity(0.88))
                .multilineTextAlignment(.trailing)
        }
    }

    private func paramsRow(_ snapshot: PhotoMetadataSnapshot) -> some View {
        let items = [
            ("光圈", formatAperture(extractValue(from: snapshot, candidates: ["FNumber", "ApertureValue"], fallback: "—"))),
            ("快门", formatShutter(extractValue(from: snapshot, candidates: ["ExposureTime"], fallback: "—"))),
            ("ISO", formatISO(extractValue(from: snapshot, candidates: ["ISOSpeedRatings", "PhotographicSensitivity"], fallback: "—"))),
            ("焦距", formatFocalLength(extractValue(from: snapshot, candidates: ["FocalLength"], fallback: "—")))
        ]
        return HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    Text(item.1)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black.opacity(0.86))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(item.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    private func detailList(_ snapshot: PhotoMetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow("文件名", extractValue(from: snapshot, candidates: ["originalFilename"], fallback: "—"))
            detailRow("分辨率", resolutionText(from: snapshot))
            detailRow("文件大小", extractValue(from: snapshot, candidates: ["fileSize"], fallback: "—"))
        }
    }

    private func locationList(_ snapshot: PhotoMetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let place = extractValue(from: snapshot, candidates: ["location.placeName"], fallback: "—")
            let admin = extractValue(from: snapshot, candidates: ["location.adminArea"], fallback: "—")
            if place != "—" || admin != "—" {
                detailRow("地点名", place == "—" ? "未知地点" : place)
                detailRow("行政区", admin == "—" ? "未知行政区" : admin)
            } else {
                detailRow("纬度", extractValue(from: snapshot, candidates: ["location.latitude", "GPSLatitude"], fallback: "—"))
                detailRow("经度", extractValue(from: snapshot, candidates: ["location.longitude", "GPSLongitude"], fallback: "—"))
                detailRow("海拔", extractValue(from: snapshot, candidates: ["location.altitude", "GPSAltitude"], fallback: "—"))
            }
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("•  \(key)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black.opacity(0.86))
                .multilineTextAlignment(.trailing)
        }
    }

    private func rowDictionary(from snapshot: PhotoMetadataSnapshot) -> [String: String] {
        var dict: [String: String] = [:]
        for section in snapshot.sections {
            for row in section.rows {
                dict[row.key] = row.value
            }
        }
        return dict
    }

    private func extractCameraModel(from snapshot: PhotoMetadataSnapshot) -> String {
        extractValue(from: snapshot, candidates: ["Model", "CameraOwnerName", "LensModel"], fallback: "未知设备")
    }

    private func resolutionText(from snapshot: PhotoMetadataSnapshot) -> String {
        let width = extractValue(from: snapshot, candidates: ["pixelWidth", "PixelWidth"], fallback: "—")
        let height = extractValue(from: snapshot, candidates: ["pixelHeight", "PixelHeight"], fallback: "—")
        if width == "—" || height == "—" { return "—" }
        return "\(width) × \(height)"
    }

    private func extractValue(from snapshot: PhotoMetadataSnapshot, candidates: [String], fallback: String) -> String {
        let rows = rowDictionary(from: snapshot)
        for candidate in candidates {
            if let exact = rows[candidate], !exact.isEmpty { return exact }
            if let fuzzy = rows.first(where: { $0.key.localizedCaseInsensitiveContains(candidate) && !$0.value.isEmpty })?.value {
                return fuzzy
            }
        }
        return fallback
    }

    private func formatAperture(_ raw: String) -> String {
        guard let value = parsePrimaryNumber(raw) else { return raw }
        return "f\(trimmed(value, maxFractionDigits: 1))"
    }

    private func formatShutter(_ raw: String) -> String {
        guard let value = parsePrimaryNumber(raw), value > 0 else { return raw }
        if value < 1 {
            let denominator = max(1, Int((1 / value).rounded()))
            return "1/\(denominator) s"
        }
        return "\(trimmed(value, maxFractionDigits: 2)) s"
    }

    private func formatISO(_ raw: String) -> String {
        guard let value = parsePrimaryNumber(raw) else { return raw }
        return "ISO \(Int(value.rounded()))"
    }

    private func formatFocalLength(_ raw: String) -> String {
        guard let value = parsePrimaryNumber(raw) else { return raw }
        return "\(trimmed(value, maxFractionDigits: 1)) mm"
    }

    private func parsePrimaryNumber(_ raw: String) -> Double? {
        let pattern = #"[-+]?\d*\.?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
              let range = Range(match.range, in: raw)
        else { return nil }
        return Double(String(raw[range]))
    }

    private func trimmed(_ value: Double, maxFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
