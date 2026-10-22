import Foundation
import CryptoKit

/// A recipe relative to PhotoKit's unadjusted editing input, not to our last
/// JPEG/HEIC output. The fingerprint prevents accidentally applying this recipe
/// to a different base (and silently losing an earlier editor's adjustments).
nonisolated struct PhotoRotationAdjustment: Codable, Equatable, Sendable {
    static let formatIdentifier = "app.oneday.clockwise-rotation"
    static let formatVersion = "2"

    let clockwiseQuarterTurns: Int
    let baselineFingerprint: String
    let baselineOrientation: Int32

    static func decode(formatIdentifier: String, formatVersion: String, data: Data) -> Self? {
        guard formatIdentifier == Self.formatIdentifier, formatVersion == Self.formatVersion,
              data.count <= 4096,
              let recipe = try? JSONDecoder().decode(Self.self, from: data),
              (0...3).contains(recipe.clockwiseQuarterTurns),
              (1...8).contains(recipe.baselineOrientation),
              recipe.baselineFingerprint.count == 64,
              recipe.baselineFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return recipe
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func next(after previous: Self?, baselineFingerprint: String, baselineOrientation: Int32) throws -> Self {
        if let previous {
            guard previous.baselineFingerprint == baselineFingerprint,
                  previous.baselineOrientation == baselineOrientation else {
                // Never fall back to re-encoding the last rendered output.
                throw PhotoRotationError.baselineChanged
            }
        }
        return Self(clockwiseQuarterTurns: ((previous?.clockwiseQuarterTurns ?? 0) + 1) % 4,
                    baselineFingerprint: baselineFingerprint, baselineOrientation: baselineOrientation)
    }

    static func fingerprint(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
