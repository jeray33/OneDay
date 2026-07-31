import SwiftUI

/// Configures which system albums appear as quick tags on the photo preview.
struct AlbumConfigSheet: View {
    let model: DayViewModel
    var onFinish: () -> Void

    @State private var albums: [AlbumInfo] = []
    /// Local draft of disabled album ids; committed only on Done.
    @State private var draftDisabled: Set<String> = []
    @State private var showCreate = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private var allEnabled: Bool {
        !albums.isEmpty && albums.allSatisfy { !draftDisabled.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("新建相簿…", systemImage: "plus.circle")
                    }
                }
                Section("我的相簿") {
                    if albums.isEmpty {
                        Text("还没有相簿")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(albums) { album in
                        Toggle(isOn: binding(for: album)) {
                            HStack {
                                Image(systemName: album.id == AlbumInfo.hiddenAlbumID ? "eye.slash" : "rectangle.stack")
                                    .foregroundStyle(Theme.accent)
                                Text(album.title)
                                Spacer()
                                if album.id != AlbumInfo.hiddenAlbumID {
                                    Text("\(album.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(Theme.accent)
                    }
                    .onMove(perform: moveAlbums)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("相簿标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allEnabled ? "取消全选" : "全选") {
                        if allEnabled {
                            draftDisabled = Set(albums.map(\.id))
                        } else {
                            draftDisabled.removeAll()
                        }
                    }
                    .disabled(albums.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commitAndClose() }
                        .fontWeight(.semibold)
                }
            }
            .alert("新建相簿", isPresented: $showCreate) {
                TextField("相簿名称", text: $newName)
                Button("创建") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        if let created = await model.createEmptyAlbum(named: name) {
                            // Newly created albums stay enabled by default.
                            draftDisabled.remove(created.id)
                            // Keep current draft order; append new album at end if missing.
                            var next = albums
                            if !next.contains(where: { $0.id == created.id }) {
                                next.append(created)
                            } else {
                                next = ordered(model.userAlbums() + [.hiddenAlbum], by: albums.map(\.id) + [created.id])
                            }
                            albums = next
                            newName = ""
                        }
                    }
                }
                Button("取消", role: .cancel) { newName = "" }
            }
        }
        .onAppear {
            var all = model.userAlbums()
            all.append(.hiddenAlbum)
            albums = ordered(all, by: model.albumTagOrder)
            draftDisabled = model.disabledAlbumIDs
        }
    }

    private func binding(for album: AlbumInfo) -> Binding<Bool> {
        Binding(
            get: { !draftDisabled.contains(album.id) },
            set: { on in
                if on {
                    draftDisabled.remove(album.id)
                } else {
                    draftDisabled.insert(album.id)
                }
            }
        )
    }

    private func moveAlbums(from source: IndexSet, to destination: Int) {
        albums.move(fromOffsets: source, toOffset: destination)
    }

    private func ordered(_ source: [AlbumInfo], by order: [String]) -> [AlbumInfo] {
        let byID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        var result: [AlbumInfo] = []
        var seen = Set<String>()
        for id in order {
            if let album = byID[id] {
                result.append(album)
                seen.insert(id)
            }
        }
        for album in source where !seen.contains(album.id) {
            result.append(album)
        }
        return result
    }

    private func commitAndClose() {
        model.disabledAlbumIDs = draftDisabled
        model.albumTagOrder = albums.map(\.id)
        dismiss()
        onFinish()
    }
}
