import SwiftUI
import UIKit
import os

private let waterfallLogger = Logger(subsystem: "OneDay", category: "WaterfallPerformance")

private struct SimilarPhotoReflowKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    /// Only explicit fold actions may animate the virtual grid's positions.
    var similarPhotoReflow: Bool {
        get { self[SimilarPhotoReflowKey.self] }
        set { self[SimilarPhotoReflowKey.self] = newValue }
    }
}

/// Preserve the aligned grid's existing animation, but make waterfall reflows
/// atomic so scroll-anchor corrections use final, not interpolated geometry.
func withDayGridLayoutChange(_ arrangement: DayGridArrangement, _ changes: () -> Void) {
    if arrangement == .waterfall {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    } else {
        withAnimation(.easeInOut(duration: 0.3), changes)
    }
}

/// Shared by leaf grids only. Scroll frames never invalidate the day host.
@MainActor @Observable
final class WaterfallViewport {
    private(set) var window: CGRect = .zero

    func updateWindow(_ next: CGRect) {
        if WaterfallLayoutPolicy.shouldReplaceRenderWindow(window, with: next) { window = next }
    }
}

struct WaterfallItemDescriptor: Equatable {
    enum Content: Equatable {
        case photo(aspect: CGFloat, version: String, caption: String?)
        case decoration(height: CGFloat)
    }
    let id: String
    let content: Content
}

struct WaterfallGeometry: Equatable {
    var cells: [String: HeroCellInfo] = [:]
    var cards: [String: CGRect] = [:]
    var sectionTops: [String: CGFloat] = [:]
}

struct WaterfallGeometryKey: PreferenceKey {
    static var defaultValue = WaterfallGeometry()
    static func reduce(value: inout WaterfallGeometry, nextValue: () -> WaterfallGeometry) {
        let next = nextValue()
        value.cells.merge(next.cells) { _, new in new }
        value.cards.merge(next.cards) { _, new in new }
        value.sectionTops.merge(next.sectionTops) { _, new in new }
    }
}

@MainActor
private final class PreparedWaterfall {
    let items: [WaterfallItemDescriptor]
    let metrics: [WaterfallLayoutPolicy.CellMetrics]
    let plan: WaterfallLayoutPolicy.Plan
    let visibility: WaterfallLayoutPolicy.VisibilityIndex
    let indicesByID: [String: Int]
    let configuration: WaterfallPlanCache.Configuration
    private var geometryOrigin: CGPoint?
    private var geometryMarksCards = false
    private var cachedGeometry = WaterfallGeometry()

    init(items: [WaterfallItemDescriptor], metrics: [WaterfallLayoutPolicy.CellMetrics],
         configuration: WaterfallPlanCache.Configuration) {
        self.items = items
        self.metrics = metrics
        self.configuration = configuration
        plan = WaterfallLayoutPolicy.plan(
            heights: metrics.map(\.height), columnCount: configuration.columns,
            columnWidth: configuration.width, horizontalSpacing: configuration.horizontal,
            verticalSpacing: configuration.vertical)
        visibility = WaterfallLayoutPolicy.VisibilityIndex(frames: plan.frames)
        indicesByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    func geometry(at origin: CGPoint, marksCards: Bool) -> WaterfallGeometry {
        if geometryOrigin == origin, geometryMarksCards == marksCards { return cachedGeometry }
        var geometry = WaterfallGeometry()
        for index in items.indices {
            let frame = plan.frames[index].offsetBy(dx: origin.x, dy: origin.y)
            switch items[index].content {
            case .photo(_, let version, _):
                geometry.cells[items[index].id] = HeroCellInfo(
                    rect: CGRect(origin: frame.origin, size: CGSize(
                        width: frame.width, height: metrics[index].cardHeight)),
                    border: configuration.border, bottomBorder: configuration.border,
                    cornerRadius: configuration.radius, contentVersion: version)
            case .decoration:
                geometry.cards[items[index].id] = frame
                if marksCards { geometry.sectionTops[items[index].id] = frame.minY }
            }
        }
        geometryOrigin = origin
        geometryMarksCards = marksCards
        cachedGeometry = geometry
        return geometry
    }
}

@MainActor
private final class WaterfallPlanCache {
    struct Configuration: Equatable {
        let columns: Int
        let width: CGFloat
        let horizontal: CGFloat
        let vertical: CGFloat
        let border: CGFloat
        let radius: CGFloat
        let displayScale: CGFloat
    }
    private var prepared: PreparedWaterfall?
    private struct CaptionKey: Hashable {
        let text: String
        let width: CGFloat
        let scale: CGFloat
    }
    private var captionHeights: [CaptionKey: CGFloat] = [:]
    private let captionLabel: UILabel = {
        let label = UILabel()
        let base = UIFont.systemFont(ofSize: 12)
        label.font = UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 12)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .center
        return label
    }()

    func prepare(_ items: [WaterfallItemDescriptor], configuration: Configuration) -> PreparedWaterfall {
        if let prepared, prepared.items == items, prepared.configuration == configuration { return prepared }
        let started = CFAbsoluteTimeGetCurrent()
        if captionHeights.count > 2_000 { captionHeights.removeAll(keepingCapacity: true) }
        let metrics = items.map { item -> WaterfallLayoutPolicy.CellMetrics in
            switch item.content {
            case .decoration(let height):
                return .init(cardHeight: height, captionHeight: nil)
            case .photo(let aspect, _, let caption):
                let height = caption.flatMap { $0.isEmpty ? nil : captionHeight(
                    $0, width: max(configuration.width - 8, 1), scale: configuration.displayScale) }
                return WaterfallLayoutPolicy.photoMetrics(
                    width: configuration.width, aspectRatio: aspect,
                    border: configuration.border, captionHeight: height)
            }
        }
        let result = PreparedWaterfall(items: items, metrics: metrics, configuration: configuration)
        prepared = result
        if ProcessInfo.processInfo.arguments.contains("-OneDayPerformanceTrace") {
            waterfallLogger.debug("Planned \(items.count) cells in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms")
        }
        return result
    }

    private func captionHeight(_ text: String, width: CGFloat, scale: CGFloat) -> CGFloat {
        let key = CaptionKey(text: text, width: width, scale: scale)
        if let height = captionHeights[key] { return height }
        captionLabel.text = text
        let height = ceil(captionLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height * scale) / scale
        captionHeights[key] = height
        return height
    }
}

/// The canvas keeps its full height, but only the buffered window creates
/// photo views. Complete geometry stays available for anchors and hero flights.
struct VirtualWaterfallGrid<Entry: Identifiable, Content: View>: View where Entry.ID == String {
    @Environment(\.displayScale) private var displayScale
    let entries: [Entry]
    let descriptors: [WaterfallItemDescriptor]
    let columnCount: Int
    let columnWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let border: CGFloat
    let cornerRadius: CGFloat
    let viewport: WaterfallViewport
    let pinnedIDs: Set<String>
    let marksPlaceCards: Bool
    let layoutRevision: DayGridLayoutRevision
    @ViewBuilder var content: (Entry, WaterfallLayoutPolicy.CellMetrics) -> Content
    @State private var cache = WaterfallPlanCache()
    @State private var measurement: MeasuredWaterfallOrigin?

    var body: some View {
        let prepared = cache.prepare(descriptors, configuration: .init(
            columns: columnCount, width: columnWidth, horizontal: horizontalSpacing,
            vertical: verticalSpacing, border: border, radius: cornerRadius,
            displayScale: max(displayScale, 1)))
        Color.clear
            .frame(width: prepared.plan.size.width, height: prepared.plan.size.height)
            .overlay(alignment: .topLeading) {
                if let measurement {
                    WaterfallVisibleCells(
                        entries: entries, prepared: prepared, origin: measurement.origin,
                        viewport: viewport, pinnedIDs: pinnedIDs, content: content)
                }
            }
            .background {
                if let measurement, measurement.revision == layoutRevision {
                    WaterfallGeometryReporter(
                        geometry: prepared.geometry(at: measurement.origin, marksCards: marksPlaceCards))
                }
            }
            .onGeometryChange(for: MeasuredWaterfallOrigin.self) { geometry in
                MeasuredWaterfallOrigin(
                    revision: layoutRevision, origin: geometry.frame(in: .named(dayContentSpace)).origin)
            } action: { next in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { measurement = next }
            }
    }
}

/// An earlier grid may have changed height even when this grid's own plan did
/// not. Publish its index only after measuring the current global layout.
nonisolated private struct MeasuredWaterfallOrigin: Equatable {
    let revision: DayGridLayoutRevision
    let origin: CGPoint
}

private struct WaterfallGeometryReporter: View {
    let geometry: WaterfallGeometry

    var body: some View {
        Color.clear
            .preference(key: WaterfallGeometryKey.self, value: geometry)
            .preference(key: SectionTopKey.self, value: geometry.sectionTops)
    }
}

private struct WaterfallVisibleCells<Entry: Identifiable, Content: View>: View where Entry.ID == String {
    let entries: [Entry]
    let prepared: PreparedWaterfall
    let origin: CGPoint
    let viewport: WaterfallViewport
    let pinnedIDs: Set<String>
    @ViewBuilder var content: (Entry, WaterfallLayoutPolicy.CellMetrics) -> Content

    var body: some View {
        let window = viewport.window.offsetBy(dx: -origin.x, dy: -origin.y)
        let pinned = Set(pinnedIDs.compactMap { prepared.indicesByID[$0] })
        let indices = prepared.visibility.indices(in: window, pinned: pinned)
        ZStack(alignment: .topLeading) {
            ForEach(indices.map { prepared.items[$0].id }, id: \.self) { id in
                let index = prepared.indicesByID[id]!
                let frame = prepared.plan.frames[index]
                content(entries[index], prepared.metrics[index])
                    .frame(width: frame.width, height: frame.height, alignment: .top)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(width: prepared.plan.size.width, height: prepared.plan.size.height, alignment: .topLeading)
        .transaction { if !$0.similarPhotoReflow { $0.animation = nil } }
        .onChange(of: indices, initial: true) { _, indices in
            if ProcessInfo.processInfo.arguments.contains("-OneDayPerformanceTrace") {
                waterfallLogger.debug("Rendered \(indices.count) / \(prepared.items.count) waterfall cells")
            }
        }
    }
}

/// Aligned-grid image gating. The virtual waterfall removes off-screen cells
/// altogether. Expensive Photos requests exist only near the viewport, with
/// hysteresis: a cell loads its image within one screen of the viewport and
/// stays loaded until it drifts past `WaterfallLayoutPolicy.unloadScreens`
/// screens, so cells sitting at the boundary cannot flip on and off while
/// scrolling slowly. The grid's lazy toggle only
/// decides whether the aligned grid also materializes cells lazily.
struct ViewportPhotoCell<Content: View>: View {
    let viewportSize: CGSize
    let forceLoad: Bool
    @ViewBuilder var content: (Bool) -> Content

    @State private var isLoaded = false

    var body: some View {
        content(isLoaded || forceLoad)
            .onGeometryChange(for: Bool.self) { geometry in
                WaterfallLayoutPolicy.shouldLoadImage(
                    frame: geometry.frame(in: .named(heroCoordinateSpace)),
                    viewport: CGRect(origin: .zero, size: viewportSize),
                    isLoaded: isLoaded
                )
            } action: { isLoaded = $0 }
    }
}
