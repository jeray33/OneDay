import SwiftUI

/// A simple sheet for editing a photo's caption/description.
struct CaptionEditorSheet: View {
    let item: PhotoItem
    let onSave: (String?) -> Void

    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss

    init(item: PhotoItem, onSave: @escaping (String?) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: item.caption ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("说明文字", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .font(Theme.serif(16, weight: .regular))
                } footer: {
                    Text("保存后会写入照片的元数据，并在本应用内显示。")
                        .font(Theme.serif(12, weight: .regular))
                }
            }
            .navigationTitle("编辑说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
        }
    }
}
