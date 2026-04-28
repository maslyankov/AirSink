import Foundation

/// One iOS device currently mirroring (or freshly connected) to AirSink.
struct ConnectedDevice: Identifiable, Equatable {
    let id: String           // deviceID from uxplay (MAC-style hex)
    let name: String         // user-facing, e.g. "Martin's iPhone"
    let model: String        // e.g. "iPhone15,3"
    let connectedAt: Date

    static func == (lhs: ConnectedDevice, rhs: ConnectedDevice) -> Bool {
        lhs.id == rhs.id
    }
}

/// Parses uxplay's stderr for connection lifecycle events.
enum DeviceLogParser {
    /// Matches: "connection request from Martin's iPhone (iPhone15,3) with deviceID = AA:BB:..."
    private static let connectRegex: NSRegularExpression = {
        let pattern = #"connection request from (.+?) \(([^)]+)\) with deviceID = (\S+)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Matches: "Open connections: <n>"
    private static let openCountRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: #"Open connections:\s*(\d+)"#)
    }()

    enum Event {
        case connected(ConnectedDevice)
        case openCount(Int)
    }

    static func event(in line: String) -> Event? {
        let range = NSRange(line.startIndex..., in: line)
        if let m = connectRegex.firstMatch(in: line, range: range), m.numberOfRanges == 4 {
            guard let nameR = Range(m.range(at: 1), in: line),
                  let modelR = Range(m.range(at: 2), in: line),
                  let idR    = Range(m.range(at: 3), in: line) else { return nil }
            return .connected(ConnectedDevice(
                id: String(line[idR]),
                name: String(line[nameR]),
                model: String(line[modelR]),
                connectedAt: Date()
            ))
        }
        if let m = openCountRegex.firstMatch(in: line, range: range), m.numberOfRanges == 2,
           let countR = Range(m.range(at: 1), in: line),
           let count = Int(line[countR]) {
            return .openCount(count)
        }
        return nil
    }
}
