import SwiftUI

/// A single stationary information block shared by all preview pages.
struct PreviewInfoView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: PhotoItem
    let place: String?
    var onFlipRequest: () -> Void

    private var captionColor: Color {
        colorScheme == .dark ? .white : Color(white: 0.15)
    }

    private var dateLine: String {
        let date = item.creationDate ?? Date()
        let zone = item.captureTimeZone
        let c = DateText.components(date, in: zone)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = zone
        let line = "\(c.year).\(c.month).\(c.day) \(DateText.weekday(date, in: zone)) \(f.string(from: date))"
        guard let offset = CaptureClock.current().offsetLabel(for: zone, at: date) else { return line }
        return "\(line) \(offset)"
    }

    private var infoCaption: String? {
        let text = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var body: some View {
        VStack(spacing: 2) {
            if let place, !place.isEmpty {
                Text(place)
                    .font(Theme.serif(14, weight: .semibold))
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
            } else if item.location != nil {
                // Keep the row stable while the asynchronous place name loads.
                Text(" ")
                    .font(Theme.serif(14, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)
            }
            Text(dateLine)
                .font(Theme.serif(11))
                .foregroundStyle(captionColor.opacity(0.82))
                .lineLimit(1)
            if let infoCaption {
                Text(infoCaption)
                    .font(Theme.serif(12))
                    .foregroundStyle(captionColor.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFlipRequest)
    }
}
