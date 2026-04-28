import Foundation
import AppKit
import Darwin

/// Detects whether macOS's built-in AirPlay Receiver (or anything else) is
/// holding TCP port 7000 — uxplay's default RTSP port.
enum SystemAirPlayCheck {
    /// Synchronous bind probe. Returns true if port 7000 is bound by another
    /// process (most commonly the system AirPlay Receiver).
    static func isReceiverPortInUse() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(7000).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)  // INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0  // bind() returned -1 → EADDRINUSE (or similar)
    }

    /// Open the AirDrop & Handoff settings pane (where AirPlay Receiver lives
    /// on macOS Ventura+).
    static func openReceiverSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}

