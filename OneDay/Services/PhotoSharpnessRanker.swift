import UIKit
import CoreImage
import Photos
import os

/// Ranks photos by perceived sharpness using Laplacian variance on a small
/// grayscale thumbnail. Higher variance = more high-frequency detail =
/// "sharper / better composed" heuristic for picking cover representatives.
actor PhotoSharpnessRanker {
    static let shared = PhotoSharpnessRanker()

    private nonisolated static let sampleSize = 128
    private nonisolated static let logger = Logger(subsystem: "OneDay", category: "CoverPerformance")

    private enum Result: Sendable {
        case score(Int, Double?)
        case deadline
    }

    nonisolated func rank(assets: [PHAsset], top: Int) async -> [Int] {
        guard !assets.isEmpty, top > 0 else { return [] }
        let started = CFAbsoluteTimeGetCurrent()
        return await withTaskGroup(of: Result.self) { group in
            var next = 0
            func enqueue() {
                guard !Task.isCancelled, next < assets.count else { return }
                let index = next
                next += 1
                group.addTask(priority: .utility) {
                    .score(index, await self.sharpnessScore(assets[index]))
                }
            }
            for _ in 0..<min(4, assets.count) { enqueue() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(1_200))
                return .deadline
            }
            var scores: [Int: Double] = [:]
            var completed = 0
            results: for await result in group {
                guard !Task.isCancelled else { break }
                switch result {
                case .deadline:
                    break results
                case .score(let index, let score):
                    if let score { scores[index] = score }
                    completed += 1
                    if completed == assets.count { break results }
                    enqueue()
                }
            }
            group.cancelAll()
            Self.logger.debug("Cover ready in \((CFAbsoluteTimeGetCurrent() - started) * 1000) ms; local scores: \(scores.count)")
            return CoverSelectionPolicy.rankedIndices(scores: scores, count: assets.count, top: top)
        }
    }

    private nonisolated func sharpnessScore(_ asset: PHAsset) async -> Double? {
        guard let image = await ImageLoader.shared.thumbnail(
                asset: asset, size: CGSize(width: 128, height: 128), allowsNetworkAccess: false),
              !Task.isCancelled,
              let gray = grayscaleBytes(image, size: Self.sampleSize) else { return nil }
        return laplacianVariance(gray, edge: Self.sampleSize)
    }

    /// Renders a thumbnail to an 8-bit grayscale byte array.
    private nonisolated func grayscaleBytes(_ image: UIImage, size: Int) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let cg = image.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) { out[i] = ptr[i] }
        return out
    }

    /// Laplacian (4-neighbour) variance over the interior pixels.
    private nonisolated func laplacianVariance(_ px: [UInt8], edge n: Int) -> Double {
        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                let v = 4.0 * Double(px[i])
                    - Double(px[i - n])
                    - Double(px[i + n])
                    - Double(px[i - 1])
                    - Double(px[i + 1])
                sum += v
                sumSq += v * v
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return (sumSq / count) - (mean * mean)
    }
}
