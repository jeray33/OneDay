import SwiftUI

/// Horizontal strip of album chips shown at the bottom of photo preview.
/// Leading chip opens configuration; other chips toggle membership for the current photo.
struct AlbumTagBar: View {
    let albums: [AlbumInfo]
    /// Album ids that currently contain the previewed photo.
    let membershipIDs: Set<String>
    var onConfigure: () -> Void
    var onTapAlbum: (AlbumInfo) -> Void
    @State private var flashAlbumID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                configChip
                ForEach(albums) { album in
                    albumChip(album)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var configChip: some View {
        Button(action: onConfigure) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 28)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("配置相簿标签")
    }

    @ViewBuilder
    private func albumChip(_ album: AlbumInfo) -> some View {
        if album.id == AlbumInfo.hiddenAlbumID {
            hiddenAlbumChip
        } else {
            regularAlbumChip(album)
        }
    }

    private var hiddenAlbumChip: some View {
        Button {
            onTapAlbum(.hiddenAlbum)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .bold))
                Text(AlbumInfo.hiddenAlbum.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("隐藏当前照片")
    }

    private func regularAlbumChip(_ album: AlbumInfo) -> some View {
        let inAlbum = membershipIDs.contains(album.id)
        let flashing = flashAlbumID == album.id
        return Button {
            flashAlbumID = album.id
            onTapAlbum(album)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                if flashAlbumID == album.id { flashAlbumID = nil }
            }
        } label: {
            HStack(spacing: 5) {
                if inAlbum {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                if flashing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(album.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                .ultraThinMaterial,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(inAlbum ? Color.red.opacity(0.95) : Color.clear, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.18), value: inAlbum)
            .animation(.easeInOut(duration: 0.18), value: flashing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inAlbum ? "从相簿 \(album.title) 移除" : "加入相簿 \(album.title)")
    }
}
