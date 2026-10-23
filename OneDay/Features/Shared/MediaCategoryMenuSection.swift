import SwiftUI
import Combine

struct MediaCategoryMenuSection: View {
    @Binding var selection: MediaCategorySelection
    var primaryAlwaysOn = false
    @State private var isIndexing = ImageClassificationStore.shared.isIndexing

    var body: some View {
        Section() {
            ForEach(MediaCategory.allCases) { category in
                if category == .photoVideo && primaryAlwaysOn {
                    Toggle(isOn: .constant(true)) {
                        Label(category.tabLabel, systemImage: category.icon)
                    }
                    .accessibilityHint("始终显示")
                } else {
                    Toggle(
                        isOn: Binding(
                            get: { selection.includes(category) },
                            set: { selection = selection.setting(category, enabled: $0) }
                        )
                    ) {
                        Label(category.tabLabel, systemImage: category.icon)
                    }
                }
            }
            if selection.needsImageClassification {
                Text(isIndexing ? "正在识别其它图片…" : "自动近似分类，无法判断的暂按照片显示")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageClassificationChanged).receive(on: RunLoop.main)) { _ in
            isIndexing = ImageClassificationStore.shared.isIndexing
        }
        .onAppear { isIndexing = ImageClassificationStore.shared.isIndexing }
    }
}
