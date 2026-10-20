import SwiftUI
import Combine

struct MediaCategoryMenuSection: View {
    @Binding var selection: MediaCategorySelection
    var photoAlwaysOn = false
    @State private var isIndexing = ImageClassificationStore.shared.isIndexing

    var body: some View {
        Section("显示内容") {
            ForEach(MediaCategory.allCases) { category in
                if category == .photo && photoAlwaysOn {
                    Label("照片（始终显示）", systemImage: "checkmark")
                } else {
                    Toggle(
                        isOn: Binding(
                            get: { selection.includes(category) },
                            set: { selection = selection.setting(category, enabled: $0) }
                        )
                    ) {
                        Label(category.label, systemImage: category.icon)
                    }
                }
            }
            if selection.needsImageClassification {
                Text(isIndexing ? "正在识别其他图片…" : "自动近似分类，无法判断的暂按照片显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageClassificationChanged).receive(on: RunLoop.main)) { _ in
            isIndexing = ImageClassificationStore.shared.isIndexing
        }
        .onAppear { isIndexing = ImageClassificationStore.shared.isIndexing }
    }
}
