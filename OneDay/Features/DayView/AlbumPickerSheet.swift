import SwiftUI

struct AlbumPickerSheet: View {
    let item: PhotoItem
    let model: DayViewModel
    var onFinish: () -> Void

    @State private var albums: [AlbumInfo] = []
    @State private var showCreate = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

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
                        Button {
                            Task {
                                await model.addToAlbum(album, item: item)
                                finish()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(Theme.accent)
                                Text(album.title)
                                Spacer()
                                Text("\(album.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(Theme.ink)
                    }
                }
            }
            .navigationTitle("加入相簿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish() }
                }
            }
            .alert("新建相簿", isPresented: $showCreate) {
                TextField("相簿名称", text: $newName)
                Button("创建") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        await model.createAlbum(named: name, item: item)
                        finish()
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .onAppear { albums = model.userAlbums() }
    }

    private func finish() {
        dismiss()
        onFinish()
    }
}
