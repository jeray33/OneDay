import Foundation
import Network

nonisolated enum VideoDownloadPolicy {
    static func allows(satisfied: Bool, wifi: Bool, cellular: Bool, expensive: Bool, constrained: Bool) -> Bool {
        satisfied && wifi && !cellular && !expensive && !constrained
    }
}

/// PhotoKit has no Wi-Fi-only request option. Gate requests on the current
/// route and cancel them immediately when that route stops being eligible.
nonisolated final class VideoWiFiAccess: @unchecked Sendable {
    static let shared = VideoWiFiAccess()
    private let lock = NSLock()
    private let monitor = NWPathMonitor()
    private var permission: Bool?
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = VideoDownloadPolicy.allows(
                satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi),
                cellular: path.usesInterfaceType(.cellular), expensive: path.isExpensive,
                constrained: path.isConstrained)
            guard let self else { return }
            let callbacks = self.lock.withLock {
                self.permission = allowed
                return Array(self.observers.values)
            }
            for callback in callbacks { callback(allowed) }
        }
        monitor.start(queue: DispatchQueue(label: "OneDay.video-wifi"))
    }

    var isAllowed: Bool { lock.withLock { permission == true } }

    func currentPermission() async -> Bool {
        if let known = lock.withLock({ permission }) { return known }
        let stream = AsyncStream<Bool> { continuation in
            let token = observe { allowed in
                continuation.yield(allowed)
                continuation.finish()
            }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                timeout.cancel()
                self?.removeObserver(token)
            }
        }
        for await allowed in stream { return !Task.isCancelled && allowed }
        return false
    }

    func observe(_ callback: @escaping @Sendable (Bool) -> Void) -> UUID {
        let token = UUID()
        let initial = lock.withLock {
            observers[token] = callback
            return permission
        }
        if let initial { callback(initial) }
        return token
    }

    func removeObserver(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }
}
