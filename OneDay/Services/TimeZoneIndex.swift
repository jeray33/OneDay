import Foundation

/// Offline coordinate → IANA time zone lookup over a 0.1° grid derived from
/// GeoNames `cities1000` (CC BY 4.0): each cell holding a town maps to the
/// zone of its most populous town. Only cells within ~10 km of a border can
/// pick the neighboring zone. See `Tools/make_geonames_index.py` for the
/// file layout.
nonisolated final class TimeZoneIndex: @unchecked Sendable {
    static let shared: TimeZoneIndex? = Bundle.main
        .url(forResource: "GeoNamesTimeZones", withExtension: "dat")
        .flatMap(TimeZoneIndex.init(contentsOf:))

    /// Cells searched outward (each ~11 km) before giving up on, e.g., an
    /// open-ocean coordinate.
    static let maxRing = 10

    private let zones: [TimeZone?]
    private let cells: [Int32: UInt16]
    private let lock = NSLock()
    private var memo: [Int32: TimeZone?] = [:]

    var cellCount: Int { cells.count }

    convenience init?(contentsOf url: URL) {
        guard let compressed = try? Data(contentsOf: url),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data
        else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= bytes.count else { return nil }
            var value: T = 0
            for i in 0..<size { value |= T(truncatingIfNeeded: bytes[offset + i]) << (8 * i) }
            offset += size
            return value
        }
        guard bytes.count >= 4, Array(bytes[0..<4]) == Array("TZG1".utf8) else { return nil }
        offset = 4
        guard let zoneCount = read(UInt16.self) else { return nil }
        var zones: [TimeZone?] = []
        zones.reserveCapacity(Int(zoneCount))
        for _ in 0..<zoneCount {
            guard let length = read(UInt8.self), offset + Int(length) <= bytes.count else { return nil }
            let identifier = String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
            offset += Int(length)
            zones.append(TimeZone(identifier: identifier))
        }
        guard let cellCount = read(UInt32.self) else { return nil }
        var cells: [Int32: UInt16] = [:]
        cells.reserveCapacity(Int(cellCount))
        for _ in 0..<cellCount {
            guard let key = read(Int32.self), let zone = read(UInt16.self),
                  Int(zone) < zones.count else { return nil }
            cells[key] = zone
        }
        self.zones = zones
        self.cells = cells
    }

    /// The zone at a coordinate, or nil when no town lies within ~110 km.
    func timeZone(latitude: Double, longitude: Double) -> TimeZone? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        let row = Self.row(latitude)
        let column = Self.column(longitude)
        let key = Self.key(row, column)

        lock.lock()
        if let cached = memo[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let zone = search(row: row, column: column)
        lock.lock()
        memo[key] = zone
        lock.unlock()
        return zone
    }

    /// Nearest occupied cell, ring by ring.
    private func search(row: Int, column: Int) -> TimeZone? {
        if let index = cells[Self.key(row, column)] { return zones[Int(index)] }
        let cosLat = max(cos((Double(row) / 10 - 90) * .pi / 180), 0.01)
        for ring in 1...Self.maxRing {
            var best: (distance: Double, index: UInt16)?
            for dRow in -ring...ring {
                for dColumn in -ring...ring where max(abs(dRow), abs(dColumn)) == ring {
                    let r = row + dRow
                    guard (0..<1800).contains(r) else { continue }
                    var c = column + dColumn
                    if c < 0 { c += 3600 }
                    if c >= 3600 { c -= 3600 }
                    guard let index = cells[Self.key(r, c)] else { continue }
                    let distance = Double(dRow * dRow) + pow(Double(dColumn) * cosLat, 2)
                    if best == nil || distance < best!.distance {
                        best = (distance, index)
                    }
                }
            }
            if let best { return zones[Int(best.index)] }
        }
        return nil
    }

    private static func row(_ latitude: Double) -> Int {
        min(Int(floor((latitude + 90) * 10)), 1799)
    }

    private static func column(_ longitude: Double) -> Int {
        min(Int(floor((longitude + 180) * 10)), 3599)
    }

    private static func key(_ row: Int, _ column: Int) -> Int32 {
        Int32(row * 3600 + column)
    }
}
