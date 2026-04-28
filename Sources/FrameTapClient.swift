import Foundation
import Network

/// Connects to the patched-uxplay frame tap (Unix domain socket) and emits
/// one Frame per access unit. See lib/frame_tap.h for the wire format.
final class FrameTapClient {
    enum Codec: UInt8 {
        case h264 = 1
        case h265 = 2
    }

    struct Frame {
        let codec: Codec
        let ptsNs: UInt64
        let data: Data  // Annex-B NALUs, may include SPS/PPS/VPS plus VCL
    }

    enum ConnState {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    var onFrame: ((Frame) -> Void)?
    var onState: ((ConnState) -> Void)?

    private let queue = DispatchQueue(label: "airsink.frametap.client")
    private var connection: NWConnection?
    private var buffer = Data()
    private var sawHandshake = false
    private var socketPath: String?
    private var shouldRetry = false
    private var retryWorkItem: DispatchWorkItem?

    deinit { connection?.cancel() }

    func connect(to socketPath: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.socketPath = socketPath
            self.shouldRetry = true
            self.openConnection()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRetry = false
            self.retryWorkItem?.cancel()
            self.connection?.cancel()
            self.connection = nil
            self.report(.idle)
        }
    }

    // MARK: - Internals

    private func openConnection() {
        guard let path = socketPath else { return }
        retryWorkItem?.cancel()
        connection?.cancel()
        buffer.removeAll(keepingCapacity: true)
        sawHandshake = false

        let endpoint = NWEndpoint.unix(path: path)
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup, .preparing:
                self.report(.connecting)
            case .ready:
                self.report(.connected)
                self.scheduleReceive()
            case .waiting(let err):
                // Socket file probably doesn't exist yet — uxplay still booting.
                self.report(.connecting)
                self.scheduleRetry(after: 0.5, reason: "waiting: \(err.localizedDescription)")
            case .failed(let err):
                self.report(.failed(err.localizedDescription))
                self.scheduleRetry(after: 1.0, reason: err.localizedDescription)
            case .cancelled:
                if self.shouldRetry {
                    self.scheduleRetry(after: 0.5, reason: "cancelled")
                } else {
                    self.report(.idle)
                }
            @unknown default:
                break
            }
        }

        report(.connecting)
        conn.start(queue: queue)
    }

    private func scheduleRetry(after seconds: TimeInterval, reason: String) {
        guard shouldRetry else { return }
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.openConnection() }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func report(_ state: ConnState) {
        onState?(state)
    }

    private func scheduleReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                self.report(.failed(error.localizedDescription))
                self.connection?.cancel()
                return
            }
            if isComplete {
                // Peer closed — reconnect (uxplay probably restarted).
                self.connection?.cancel()
                return
            }
            self.scheduleReceive()
        }
    }

    /// Pull as many complete messages out of `buffer` as possible.
    private func drainBuffer() {
        // Handshake: "AIRT" + 1 byte version, exactly 5 bytes once.
        if !sawHandshake {
            guard buffer.count >= 5 else { return }
            let magic = buffer.prefix(4)
            let version = buffer[buffer.startIndex + 4]
            guard magic == Data("AIRT".utf8) else {
                report(.failed("bad handshake magic"))
                connection?.cancel()
                return
            }
            guard version == 1 else {
                report(.failed("unsupported tap protocol v\(version)"))
                connection?.cancel()
                return
            }
            buffer.removeFirst(5)
            sawHandshake = true
        }

        // Per-frame header: 1 (codec) + 8 (pts BE) + 4 (len BE) = 13 bytes.
        let HEADER_LEN = 13
        while buffer.count >= HEADER_LEN {
            let codecByte = buffer[buffer.startIndex]
            let pts = readBE64(buffer, offset: 1)
            let len = Int(readBE32(buffer, offset: 9))
            guard buffer.count >= HEADER_LEN + len else { return }  // wait for more

            guard let codec = Codec(rawValue: codecByte) else {
                // Unknown codec — skip this frame to stay in sync.
                buffer.removeFirst(HEADER_LEN + len)
                continue
            }
            let payload = buffer.subdata(in: (buffer.startIndex + HEADER_LEN) ..< (buffer.startIndex + HEADER_LEN + len))
            buffer.removeFirst(HEADER_LEN + len)

            onFrame?(Frame(codec: codec, ptsNs: pts, data: payload))
        }
    }

    private func readBE64(_ data: Data, offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[data.startIndex + offset + i]) }
        return v
    }

    private func readBE32(_ data: Data, offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[data.startIndex + offset + i]) }
        return v
    }
}
