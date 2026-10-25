import Foundation

/// Stores only completed digests, keyed by algorithm and Photos content version.
/// Never stores video bytes, failed reads or an unversioned "duplicate" flag.
nonisolated final class VerifiedVideoDigestStore: @unchecked Sendable {
    static let shared = VerifiedVideoDigestStore(url: FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OneDay/verified-video-digests-v1.json"))

    private struct Entry: Codable {
        let digest: String
        var access: UInt64
    }
    private struct Snapshot: Codable {
        let version: Int
        let entries: [String: Entry]
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "OneDay.verified-video-digests")
    private let url: URL?
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0

    init(url: URL?, capacity: Int = 1_024) {
        self.url = url
        self.capacity = max(1, capacity)
        if let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 2_097_152, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1 {
            entries = saved.entries.filter { Self.valid($0.value.digest) }
            sequence = entries.values.map(\.access).max() ?? 0
            trim()
        }
    }

    func digest(for key: String) -> String? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            sequence &+= 1
            entry.access = sequence
            entries[key] = entry
            return entry.digest
        }
    }

    func record(_ digest: String, for key: String) {
        guard Self.valid(digest) else { return }
        lock.withLock {
            sequence &+= 1
            entries[key] = Entry(digest: digest, access: sequence)
            trim()
        }
        queue.async { [self] in
            guard let url else { return }
            let snapshot = lock.withLock { Snapshot(version: 1, entries: entries) }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Used by cache persistence tests, not on the UI path.
    func flush() { queue.sync {} }

    private func trim() {
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            entries.removeValue(forKey: oldest.key)
        }
    }

    private static func valid(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
