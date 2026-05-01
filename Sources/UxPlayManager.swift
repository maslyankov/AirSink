import Foundation
import AppKit
import Combine

/// Fleet of uxplay instances with on-demand allocation: at any moment there
/// is exactly 1 free instance waiting for the next device. As soon as that
/// instance is occupied, another free one spawns. When a slot empties, the
/// extra (older, previously-waiting) instance is reclaimed.
@MainActor
final class UxPlayManager: ObservableObject {
    @Published private(set) var instances: [UxPlayInstance] = []
    @Published private(set) var receiversEnabled: Bool = false

    @Published var basePort: Int = 7100
    @Published var deviceNameBase: String = UxPlayManager.defaultBaseName()
    @Published var debugLog: Bool = true

    @Published private(set) var systemReceiverActive: Bool = false

    /// Aggregate child @Published changes so SwiftUI redraws on any nested update.
    private var childCancellables: [AnyCancellable] = []
    /// Per-instance Combine subscriptions for state/devices changes.
    private var instanceObservers: [UUID: [AnyCancellable]] = [:]
    /// Monotonic slot id; survives churn so display labels stay distinct.
    private var nextSlotId: Int = 1
    /// Ports currently in use by spawned instances. Reused when an instance dies.
    private var allocatedPorts: Set<Int> = []
    /// Cap on simultaneous slots — defends against runaway spawn loops.
    private let maxConcurrentSlots: Int = 16

    init() {
        refreshSystemReceiverStatus()
    }

    // MARK: - Public actions

    func startAll() {
        refreshSystemReceiverStatus()
        receiversEnabled = true
        maintainPool()
    }

    func stopAll() {
        receiversEnabled = false
        let toStop = instances
        instances.removeAll()
        for inst in toStop { inst.stop() }
        for id in instanceObservers.keys { instanceObservers[id] = nil }
        instanceObservers.removeAll()
        allocatedPorts.removeAll()
        nextSlotId = 1
    }

    /// Drop the slot the device is on entirely; maintainPool will spawn a
    /// fresh waiting slot if one isn't already present.
    func disconnect(deviceId: String) {
        guard let inst = instance(for: deviceId) else { return }
        removeInstance(inst)
        maintainPool()
    }

    func clearAllLogs() {
        for inst in instances { inst.clearLog() }
    }

    func refreshSystemReceiverStatus() {
        systemReceiverActive = SystemAirPlayCheck.isReceiverPortInUse()
    }

    // MARK: - Pool maintenance (the dynamic core)

    /// Enforce the invariant: while enabled, exactly 1 free (or starting)
    /// instance is waiting, plus however many are currently occupied.
    private func maintainPool() {
        guard receiversEnabled else { return }

        let alive = instances.filter { inst in
            switch inst.state {
            case .stopped, .failed: return false
            case .starting, .running: return true
            }
        }
        let free = alive.filter { $0.devices.isEmpty }

        if free.isEmpty, alive.count < maxConcurrentSlots {
            spawnInstance()
            return
        }
        if free.count > 1 {
            // Keep the lowest-id free slot — newest extras get reclaimed so
            // slot numbers stay small instead of climbing forever.
            let sorted = free.sorted { $0.slotIndex < $1.slotIndex }
            for extra in sorted.dropFirst() { removeInstance(extra) }
        }
    }

    private func spawnInstance() {
        let port = (basePort ..< basePort + maxConcurrentSlots)
            .first { !allocatedPorts.contains($0) }
        guard let port else { return }
        allocatedPorts.insert(port)

        let inst = UxPlayInstance(
            slotIndex: nextSlotId,
            port: port,
            baseName: deviceNameBase,
            binaryPath: binaryPath,
            extraArgs: { [weak self] in self?.debugLog == true ? ["-d"] : [] }
        )
        nextSlotId += 1

        observeInstance(inst)
        instances.append(inst)
        rewireChildBubbles()
        inst.start()
    }

    private func removeInstance(_ inst: UxPlayInstance) {
        inst.stop()
        instances.removeAll { $0.id == inst.id }
        instanceObservers.removeValue(forKey: inst.id)
        allocatedPorts.remove(inst.port)
        rewireChildBubbles()
    }

    private func observeInstance(_ inst: UxPlayInstance) {
        // dropFirst() is critical — @Published fires the current value the
        // moment we subscribe. The initial value is .stopped, and reacting
        // to it would call removeInstance → spawn → subscribe → .stopped →
        // spawn → … → stack overflow.
        let stateCancel = inst.$state.dropFirst().sink { [weak self, weak inst] state in
            guard let self, let inst else { return }
            // Reclaim slots only on TRANSITIONS into .failed or .stopped
            // (process exited or crashed after we started it).
            switch state {
            case .failed, .stopped:
                self.removeInstance(inst)
                self.maintainPool()
            case .starting, .running:
                break
            }
        }
        let devicesCancel = inst.$devices.dropFirst().sink { [weak self] _ in
            // Defer one tick so the device array is settled before we react.
            DispatchQueue.main.async { self?.maintainPool() }
        }
        instanceObservers[inst.id] = [stateCancel, devicesCancel]
    }

    private func rewireChildBubbles() {
        childCancellables.removeAll()
        for inst in instances {
            let c1 = inst.$state.sink { [weak self] _ in self?.objectWillChange.send() }
            let c2 = inst.$devices.sink { [weak self] _ in self?.objectWillChange.send() }
            let c3 = inst.$logTail.sink { [weak self] _ in self?.objectWillChange.send() }
            childCancellables.append(contentsOf: [c1, c2, c3])
        }
    }

    // MARK: - Lookups

    func instance(for deviceId: String) -> UxPlayInstance? {
        instances.first { $0.devices.contains(where: { $0.id == deviceId }) }
    }

    var allDevices: [(instance: UxPlayInstance, device: ConnectedDevice)] {
        instances.flatMap { inst in inst.devices.map { (inst, $0) } }
    }

    // MARK: - Aggregate state

    var anyActive: Bool { receiversEnabled || instances.contains { $0.state.isActive } }
    var anyFailed: Bool { instances.contains { if case .failed = $0.state { return true }; return false } }
    var allStopped: Bool { instances.allSatisfy { $0.state == .stopped } }
    var totalDevices: Int { instances.reduce(0) { $0 + $1.devices.count } }
    var freeSlotCount: Int { instances.filter { $0.devices.isEmpty && $0.state.isActive }.count }

    // MARK: - Binary discovery

    var binaryPath: String? {
        var candidates: [String] = []
        // 1. Bundled inside the .app (DMG / brew cask distribution)
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "uxplay")?.path {
            candidates.append(bundled)
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("uxplay").path {
            candidates.append(resources)
        }
        // 2. Local development build, relative to working dir
        let cwd = FileManager.default.currentDirectoryPath
        candidates.append("\(cwd)/vendor/UxPlay/build/uxplay")
        // 3. Homebrew (works as a fallback but lacks our -tap flag → no native render)
        candidates.append("/opt/homebrew/bin/uxplay")
        candidates.append("/usr/local/bin/uxplay")
        candidates.append("/opt/local/bin/uxplay")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when the resolved binary is our patched build (supports -tap).
    /// Path-based heuristic: bundled binaries live under .app/Contents/...,
    /// dev builds under vendor/UxPlay. Stock Homebrew uxplay won't match.
    var binarySupportsTap: Bool {
        guard let path = binaryPath else { return false }
        return path.contains("/Contents/MacOS/") || path.contains("/Contents/Resources/")
            || path.contains("vendor/UxPlay")
    }

    static func defaultBaseName() -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        return host.isEmpty ? "Mac" : host
    }
}
