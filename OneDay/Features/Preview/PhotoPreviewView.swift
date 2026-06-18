import SwiftUI

struct PhotoPreviewView: View {
    let model: DayViewModel
    let namespace: Namespace.ID

    @State private var selection: String
    @State private var dragOffset: CGSize = .zero
    @State private var isZoomed = false
    @State private var albumItem: PhotoItem?
    @State private var bgColor: Color = Color(white: 0.06)
    @State private var bgOpacity: Double = 0
    @Environment(\.dismiss) private var dismiss

    init(model: DayViewModel, current: PhotoItem, namespace: Namespace.ID) {
        self.model = model
        self.namespace = namespace
        _selection = State(initialValue: current.id)
    }

    private var items: [PhotoItem] { model.allItems }

    private var currentItem: PhotoItem? {
        items.first { $0.id == selection }
    }

    /// 0 → resting, 1 → fully dragged down. Drives scale and fades.
    private var dragProgress: CGFloat {
        min(max(dragOffset.height, 0) / 320, 1)
    }

    var body: some View {
        ZStack {
            bgColor
                .ignoresSafeArea()
                .opacity(bgOpacity * Double(1 - dragProgress))

            TabView(selection: $selection) {
                ForEach(items) { item in
                    PreviewPageView(item: item, onZoomChanged: { isZoomed = $0 })
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .scaleEffect(1 - dragProgress * 0.18)
            .offset(dragOffset)
            .simultaneousGesture(dismissDrag)
        }
        .overlay(alignment: .top) { topBar }
        .statusBarHidden()
        .sheet(item: $albumItem) { item in
            AlbumPickerSheet(item: item, model: model, onFinish: {})
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { bgOpacity = 1 }
        }
        .onChange(of: selection) {
            isZoomed = false
            dragOffset = .zero
        }
        .task(id: selection) { await updateBackground() }
    }

    private func updateBackground() async {
        guard let item = currentItem else { return }
        if let image = await ImageLoader.shared.thumbnail(asset: item.asset,
                                                          size: CGSize(width: 40, height: 40)),
           let tone = image.deepTone() {
            withAnimation(.easeInOut(duration: 0.4)) { bgColor = Color(uiColor: tone) }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.25)) { bgOpacity = 0 }
        dismiss()
    }

    /// Apple Photos style: the photo tracks the finger, scales down and the
    /// background/controls fade. Horizontal drags fall through to paging,
    /// and the gesture is suppressed while zoomed so panning works.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                if abs(value.translation.height) > abs(value.translation.width) {
                    dragOffset = CGSize(width: value.translation.width * 0.5,
                                        height: max(value.translation.height, 0))
                }
            }
            .onEnded { value in
                guard !isZoomed else { return }
                let verticalDominant = abs(value.translation.height) > abs(value.translation.width)
                let farEnough = value.translation.height > 120
                    || value.predictedEndTranslation.height > 320
                if verticalDominant && farEnough {
                    close()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private var topBar: some View {
        HStack {
            Button { close() } label: {
                icon("xmark")
            }
            Spacer()
            if let item = currentItem {
                Button {
                    Task { await model.toggleFavorite(item) }
                } label: {
                    let fav = model.isFavorite(item)
                    Image(systemName: fav ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(fav ? Theme.accent : .white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.35), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                Menu {
                    Button {
                        albumItem = item
                    } label: {
                        Label("加入相簿…", systemImage: "rectangle.stack.badge.plus")
                    }
                    Button(role: .destructive) {
                        Task { await model.perform(.delete, on: item) }
                        close()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    icon("ellipsis")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .offset(y: isZoomed ? -14 : 0)
        .opacity(isZoomed ? 0 : Double(max(0, 1 - dragProgress * 2)))
        .animation(.easeInOut(duration: 0.22), value: isZoomed)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.35), in: Circle())
    }
}
