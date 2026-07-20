import UIKit
import CoreImage

/// Ranks photos by perceived sharpness using Laplacian variance on a small
/// grayscale thumbnail. Higher variance = more high-frequency detail =
/// "sharper / better composed" heuristic for picking cover representatives.
actor PhotoSharpnessRanker {
    static let shared = PhotoSharpnessRanker()

    private static let sampleSize = 128

    /// Returns the top `k` items sorted by sharpness score (descending).
    /// Ties are broken by item id for stability.
    func rank(_ items: [PhotoItem], top k: Int) async -> [PhotoItem] {
        guard k > 0 else { return [] }
        guard items.count > k else { return items }

        var scored: [(item: PhotoItem, score: Double)] = []
        for item in items {
            let score = await sharpnessScore(item)
            scored.append((item, score))
        }
        // Sort by score only; ties keep insertion (chronological) order.
        scored.sort { $0.score > $1.score }
        return scored.prefix(k).map(\.item)
    }

    private func sharpnessScore(_ item: PhotoItem) async -> Double {
        guard let image = await ImageLoader.shared.thumbnail(
                asset: item.asset, size: CGSize(width: 128, height: 128)),
              let gray = grayscaleBytes(image, size: Self.sampleSize) else { return 0 }
        return laplacianVariance(gray, edge: Self.sampleSize)
    }

    /// Renders a thumbnail to an 8-bit grayscale byte array.
    private func grayscaleBytes(_ image: UIImage, size: Int) -> [UInt8]? {
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
    private func laplacianVariance(_ px: [UInt8], edge n: Int) -> Double {
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
