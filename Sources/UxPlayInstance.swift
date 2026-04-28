import Foundation
import AppKit

/// One uxplay subprocess: its own port, tap socket, StreamSession, log, and
/// connected devices. The fleet (UxPlayManager) holds N of these.
@MainActor
final class UxPlayInstance: ObservableObject, Identifiable {
    enum RunState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
        var isActive: Bool {
            switch self {
            case .running, .starting: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let slotIndex: Int                 // 1-based, used in display names
    let port: Int
    let tapSocketPath: String

    @Published private(set) var state: RunState = .stopped
    @Published private(set) var logTail: [String] = []
    @Published private(set) var devices: [ConnectedDevice] = []

    /// Display name for AirPlay advertisement, e.g. "Mac (AirSink 1)".
    var displayName: String {
        "\(baseName) (AirSink \(slotIndex))"
    }

    /// Native render pipeline for this slot.
    let session = StreamSession()

    private let baseName: String
    private let binaryPath: String?
    private let extraArgs: () -> [String]   // for -d toggle

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init(slotIndex: Int,
         port: Int,
         baseName: String,
         binaryPath: String?,
         extraArgs: @escaping () -> [String]) {
        self.slotIndex = slotIndex
        self.port = port
        self.baseName = baseName
        self.binaryPath = binaryPath
        self.extraArgs = extraArgs
        self.tapSocketPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("airsink-tap-\(slotIndex).sock")
    }

    func start() {
        guard !state.isActive else { return }
        guard let path = binaryPath else {
            state = .failed("uxplay not built. Run vendor/build_uxplay.sh.")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        var args: [String] = ["-n", displayName, "-p", String(port)]
        if binaryPath?.hasPrefix("/Users/maslyankov/Developer/AirSink/vendor") == true {
            args.append(contentsOf: ["-tap", tapSocketPath])
        }
        args.append(contentsOf: extraArgs())
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        // Read by our patched uxplay's __attribute__((constructor)) to demote
        // NSApp to accessory before any window is created → no Dock icon.
        env["AIRSINK_HIDE_DOCK"] = "1"
        p.environment = env

        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(s) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(s) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.session.stop()
                self.devices.removeAll()
                if proc.terminationStatus == 0 || proc.terminationReason == .uncaughtSignal {
                    self.state = .stopped
                } else {
                    let recent = self.logTail.suffix(3).joined(separator: " | ")
                    self.state = .failed("uxplay exited (code \(proc.terminationStatus)). \(recent)")
                }
            }
        }

        do {
            state = .starting
            append("$ \(path) \(args.joined(separator: " "))")
            try p.run()
            process = p; stdoutPipe = out; stderrPipe = err
            state = .running
            if binaryPath?.hasPrefix("/Users/maslyankov/Developer/AirSink/vendor") == true {
                session.start(socketPath: tapSocketPath)
            }
        } catch {
            state = .failed("Launch failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        session.stop()
        process?.terminate()
    }

    /// Force-disconnect a single device. uxplay can't drop one client cleanly,
    /// so this stop+starts the slot.
    func disconnect(deviceId: String) {
        devices.removeAll { $0.id == deviceId }
        if state.isActive {
            stop()
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
    }

    func clearLog() { logTail.removeAll() }

    private func append(_ chunk: String) {
        let lines = chunk.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        logTail.append(contentsOf: lines)
        if logTail.count > 300 { logTail.removeFirst(logTail.count - 300) }
        for line in lines { applyLogEvent(line) }
    }

    private func applyLogEvent(_ line: String) {
        guard let event = DeviceLogParser.event(in: line) else { return }
        switch event {
        case .connected(let device):
            if !devices.contains(where: { $0.id == device.id }) {
                devices.append(device)
            }
        case .openCount(let n):
            if n == 0 { devices.removeAll() }
        }
    }
}
