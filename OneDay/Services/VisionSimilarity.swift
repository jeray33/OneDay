import Vision
import Photos
import UIKit

/// Groups visually-similar photos using Vision feature prints.
/// Replaces the heuristic burst check; falls back gracefully when a print is unavailable.
actor VisionSimilarity {
    static let shared = VisionSimilarity()

    private var prints: [String: VNFeaturePrintObservation] = [:]

    func featurePrint(for item: PhotoItem) async -> VNFeaturePrintObservation? {
        if let cached = prints[item.id] { return cached }
        guard !item.isVideo,
              let image = await ImageLoader.shared.thumbnail(
                asset: item.asset, size: CGSize(width: 160, height: 160)),
              let cgImage = image.cgImage else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            if let observation = request.results?.first as? VNFeaturePrintObservation {
                prints[item.id] = observation
                return observation
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Precompute feature prints for a bounded set of items.
    func warmUp(_ items: [PhotoItem]) async {
        for item in items {
            _ = await featurePrint(for: item)
        }
    }

    func distance(_ a: PhotoItem, _ b: PhotoItem) -> Float? {
        guard let pa = prints[a.id], let pb = prints[b.id] else { return nil }
        var value: Float = 0
        do {
            try pa.computeDistance(&value, to: pb)
            return value
        } catch {
            return nil
        }
    }
}
