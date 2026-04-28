import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var uxplay: UxPlayManager
    @EnvironmentObject var windows: DeviceWindowsCoordinator
    @State private var advancedExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                slotIndicator
                if uxplay.systemReceiverActive { systemReceiverBanner }
                devicesSection
                advancedSection
                versionFootnote
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 620)
        .onAppear { windows.bind(uxplay) }
        .onChange(of: uxplay.allDevices.map(\.device.id)) { _ in
            let devices = uxplay.allDevices.map(\.device)
            windows.reconcile(with: devices)
            for d in devices where !windows.isOpen(d.id) {
                windows.show(d)
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().stroke(statusColor.opacity(0.3), lineWidth: 6)
                            .scaleEffect(uxplay.anyActive ? 1.6 : 1.0)
                            .opacity(uxplay.anyActive ? 0 : 1)
                            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                       value: uxplay.anyActive)
                    )
                Text(statusTitle)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            if let sub = statusSubtitle {
                Text(sub)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: toggleAll) {
                Text(uxplay.anyActive ? "Stop all" : "Start receivers")
                    .frame(minWidth: 160).padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(uxplay.binaryPath == nil)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        )
    }

    private var statusColor: Color {
        if uxplay.anyActive { return .green }
        if uxplay.anyFailed { return .red }
        return Color.secondary.opacity(0.6)
    }

    private var statusTitle: String {
        if uxplay.anyActive { return "Receivers Active" }
        if uxplay.anyFailed { return "Receivers Stopped" }
        return "Receivers Off"
    }

    private var statusSubtitle: String? {
        if uxplay.anyActive {
            let n = uxplay.totalDevices
            let free = uxplay.freeSlotCount
            let devicesPart = n == 0 ? "no devices yet" : "\(n) device\(n == 1 ? "" : "s") connected"
            let waitingPart = free > 0 ? " · 1 slot waiting" : " · spawning slot…"
            return devicesPart + waitingPart
        }
        if uxplay.binaryPath == nil {
            return "uxplay not built — run vendor/build_uxplay.sh"
        }
        return "Click Start, then mirror from any iPhone or iPad."
    }

    private func toggleAll() {
        if uxplay.anyActive { uxplay.stopAll() } else { uxplay.startAll() }
    }

    // MARK: - Slot indicator

    private var slotIndicator: some View {
        HStack(spacing: 6) {
            ForEach(uxplay.instances) { inst in
                SlotPill(instance: inst)
            }
            Spacer()
        }
    }

    // MARK: - System receiver banner

    private var systemReceiverBanner: some View {
        let willClash = uxplay.basePort <= 7000 && (uxplay.basePort + 16) > 7000
        return HStack(spacing: 10) {
            Image(systemName: willClash ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(willClash ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(willClash ? "Port 7000 conflict" : "macOS AirPlay Receiver coexists")
                    .font(.callout).bold()
                Text(willClash
                     ? "Move AirSink's base port off 7000 or disable the system receiver."
                     : "Both will appear in your iPhone's Screen Mirroring picker.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Settings") { SystemAirPlayCheck.openReceiverSettings() }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((willClash ? Color.orange : Color.secondary).opacity(0.10))
        )
    }

    // MARK: - Devices section

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connected devices").font(.headline)
                Spacer()
                Text(uxplay.totalDevices == 0 ? "None" : "\(uxplay.totalDevices)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            if uxplay.totalDevices == 0 {
                emptyDevicesRow
            } else {
                VStack(spacing: 6) {
                    ForEach(uxplay.allDevices, id: \.device.id) { entry in
                        DeviceRow(instance: entry.instance, device: entry.device)
                    }
                }
            }
        }
    }

    private var emptyDevicesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3.slash")
                .foregroundStyle(.secondary).font(.title3)
            Text(uxplay.anyActive
                 ? "Waiting for an iPhone or iPad to mirror — a new slot opens after each one connects."
                 : "Start the receivers to accept connections.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                fleetSettings
                if uxplay.binaryPath == nil { installHint }
                logBox
                footerLinks
            }
            .padding(.top, 10)
        } label: {
            Label("Advanced", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var fleetSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Allocation") {
                Text("Slots are spawned on demand — one is always waiting for the next device.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Device name") {
                TextField("Base name", text: $uxplay.deviceNameBase)
                    .textFieldStyle(.roundedBorder).labelsHidden()
            }
            LabeledContent("Base port") {
                HStack {
                    TextField("Base port", value: $uxplay.basePort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 80)
                    Text("Slots draw from \(uxplay.basePort)…\(uxplay.basePort + 15)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Verbose uxplay output (-d)", isOn: $uxplay.debugLog)
                .toggleStyle(.checkbox)
        }
        .disabled(uxplay.anyActive)
    }

    private var installHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("uxplay not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
            Text("./vendor/build_uxplay.sh")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(6).background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
    }

    private var logBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.caption).bold()
                Spacer()
                Button("Clear") { uxplay.clearAllLogs() }
                    .buttonStyle(.link).font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let merged = mergedLog
                        ForEach(Array(merged.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("[\(item.slot)]")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(item.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(idx)
                        }
                    }.padding(6)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
                .onChange(of: mergedLog.count) { count in
                    guard count > 0 else { return }
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Interleave each slot's tail; truncate to most recent 200 entries.
    private var mergedLog: [(slot: Int, line: String)] {
        var combined: [(slot: Int, line: String, idx: Int)] = []
        for inst in uxplay.instances {
            for (i, l) in inst.logTail.enumerated() {
                combined.append((slot: inst.slotIndex, line: l, idx: i))
            }
        }
        // Best-effort interleave by per-slot index (stable across slots).
        let sorted = combined.sorted { $0.idx < $1.idx }
        let trimmed = sorted.suffix(200)
        return trimmed.map { (slot: $0.slot, line: $0.line) }
    }

    private var footerLinks: some View {
        HStack {
            Button("AirPlay Receiver Settings…") {
                SystemAirPlayCheck.openReceiverSettings()
            }.buttonStyle(.link)
            Spacer()
            let totalFrames = uxplay.instances.reduce(0) { $0 + $1.session.frameCount }
            if totalFrames > 0 {
                Text("\(totalFrames) frames decoded")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

// MARK: - Subtle version footer (rendered at bottom of the main scroll)

extension ContentView {
    fileprivate var versionFootnote: some View {
        Text(AppInfo.displayString)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }
}

// MARK: - Subviews

private struct SlotPill: View {
    @ObservedObject var instance: UxPlayInstance

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("Slot \(instance.slotIndex)")
                .font(.caption2).foregroundStyle(.secondary)
            if !instance.devices.isEmpty {
                Text("·")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(instance.devices.count)")
                    .font(.caption2).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.10)))
    }

    private var color: Color {
        switch instance.state {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return Color.secondary.opacity(0.5)
        case .failed: return .red
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var windows: DeviceWindowsCoordinator
    @EnvironmentObject var uxplay: UxPlayManager
    @ObservedObject var instance: UxPlayInstance
    let device: ConnectedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.model.lowercased().contains("ipad") ? "ipad" : "iphone")
                .font(.title2)
                .foregroundStyle(streaming ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.callout).bold()
                HStack(spacing: 4) {
                    Text(device.model)
                    Text("·")
                    Text("Slot \(instance.slotIndex)")
                    Text("·")
                    if streaming, let dim {
                        Text("Streaming \(dim)").foregroundStyle(.green)
                    } else {
                        Text("Connected")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                windows.toggle(device)
            } label: {
                Label(windows.isOpen(device.id) ? "Hide" : "Show",
                      systemImage: windows.isOpen(device.id) ? "eye.slash" : "eye")
                    .labelStyle(.titleOnly)
            }
            .controlSize(.small)
            Button(role: .destructive) {
                uxplay.disconnect(deviceId: device.id)
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleOnly)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var streaming: Bool {
        if case .streaming = instance.session.state { return true }
        return false
    }

    private var dim: String? {
        if case .streaming(let w, let h) = instance.session.state { return "\(w)×\(h)" }
        return nil
    }
}
