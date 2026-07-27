import SwiftUI

struct PendingDeleteSheet: View {
    let items: [PhotoItem]
    var onCancel: () -> Void
    var onConfirm: (Set<String>) -> Void

    @State private var selectedIDs: Set<String> = []

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if items.isEmpty {
                    Text("暂无待删除照片")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { item in
                                cell(item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                    }
                    HStack(spacing: 12) {
                        Button("不删除了") {
                            onCancel()
                        }
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(height: 58)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .buttonStyle(.plain)

                        Button("确认删除") {
                            onConfirm(selectedIDs)
                        }
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 58)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(selectedIDs.isEmpty ? Color.red.opacity(0.35) : Color.red)
                        )
                        .buttonStyle(.plain)
                        .disabled(selectedIDs.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            .navigationTitle("待删除 \(selectedIDs.count)/\(items.count)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            selectedIDs = Set(items.map(\.id))
        }
    }

    private func cell(_ item: PhotoItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return Button {
            if selected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                PHImageView(
                    asset: item.asset,
                    displaySize: CGSize(width: 96, height: 96),
                    fill: true,
                    highQuality: false
                )
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .padding(6)
                    .shadow(radius: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "取消选中" : "选中")
    }
}
