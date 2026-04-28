import AppKit
import SwiftUI
import Combine

/// One NSWindow per connected device, hosting that device's stream view.
/// Today every window shares `manager.session` (single uxplay subprocess);
/// the API is shaped so each device can carry its own session later.
@MainActor
final class DeviceWindowsCoordinator: NSObject, ObservableObject {
    @Published private(set) var openIds: Set<String> = []

    private weak var manager: UxPlayManager?
    private var controllers: [String: DeviceWindowController] = [:]

    func bind(_ manager: UxPlayManager) {
        self.manager = manager
    }

    /// True if a window for `deviceId` is currently open.
    func isOpen(_ deviceId: String) -> Bool { openIds.contains(deviceId) }

    func toggle(_ device: ConnectedDevice) {
        isOpen(device.id) ? close(deviceId: device.id) : show(device)
    }

    func show(_ device: ConnectedDevice) {
        guard let manager,
              let owner = manager.instance(for: device.id) else { return }
        if let existing = controllers[device.id] {
            existing.refreshTitle(for: device, slot: owner.slotIndex)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            openIds.insert(device.id)
            return
        }
        let controller = DeviceWindowController(device: device,
                                                slot: owner.slotIndex,
                                                session: owner.session)
        controller.delegateOnClose = { [weak self] id in self?.handleWindowClosed(id) }
        controllers[device.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        openIds.insert(device.id)
    }

    func close(deviceId: String) {
        controllers[deviceId]?.close()
        // handleWindowClosed will run from windowWillClose
    }

    func closeAll() {
        for id in Array(controllers.keys) { close(deviceId: id) }
    }

    /// Drop windows for devices that no longer exist.
    func reconcile(with devices: [ConnectedDevice]) {
        let live = Set(devices.map(\.id))
        for id in Array(controllers.keys) where !live.contains(id) {
            close(deviceId: id)
        }
    }

    private func handleWindowClosed(_ id: String) {
        controllers.removeValue(forKey: id)
        openIds.remove(id)
    }
}

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    var delegateOnClose: ((String) -> Void)?
    private let deviceId: String

    init(device: ConnectedDevice, slot: Int, session: StreamSession) {
        self.deviceId = device.id

        let host = NSHostingController(rootView: DeviceWindowContent(session: session))
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 720)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(device.name) — Slot \(slot)"
        window.contentViewController = host
        window.minSize = NSSize(width: 240, height: 320)
        // Cascade so multiple device windows don't pile up on each other.
        let offset = CGFloat((slot - 1) * 30)
        window.setFrameOrigin(NSPoint(x: 120 + offset, y: 120 + offset))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func refreshTitle(for device: ConnectedDevice, slot: Int) {
        window?.title = "\(device.name) — Slot \(slot)"
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        let id = self.deviceId
        let me = self
        Task { @MainActor in me.delegateOnClose?(id) }
    }
}

/// SwiftUI content for a device window: just the live video pane.
private struct DeviceWindowContent: View {
    let session: StreamSession
    @ObservedObject private var proxy = StreamSessionProxy()

    var body: some View {
        ZStack {
            Color.black
            StreamView(session: session)
            if !isStreaming {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(statusText)
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { proxy.bind(session) }
    }

    private var isStreaming: Bool {
        if case .streaming = session.state { return true }
        return false
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Idle"
        case .connecting: return "Waiting for stream…"
        case .connected: return "Negotiating…"
        case .streaming: return ""
        case .failed(let m): return m
        }
    }
}

/// Republishes a StreamSession's @Published changes through this view's
/// own ObservableObject so the per-window UI redraws.
@MainActor
final class StreamSessionProxy: ObservableObject {
    private var bag: [AnyObject] = []
    func bind(_ session: StreamSession) {
        bag.removeAll()
        let c1 = session.$state.sink { [weak self] _ in self?.objectWillChange.send() }
        let c2 = session.$frameCount.sink { [weak self] _ in self?.objectWillChange.send() }
        bag = [c1, c2]
    }
}
