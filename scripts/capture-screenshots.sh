#!/usr/bin/env bash
# Helper to capture README screenshots of the running AirSink app.
# Requires Screen Recording permission for your terminal.
#
# Usage:  ./scripts/capture-screenshots.sh
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p docs/screenshots

if ! pgrep -x AirSink >/dev/null; then
    echo "AirSink isn't running. Launch it first, then re-run." >&2
    exit 1
fi

# List candidate windows (id + title) using Quartz/CoreGraphics
swift - <<'SWIFT'
import AppKit
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let id    = w[kCGWindowNumber as String] as? Int ?? 0
    let title = w[kCGWindowName as String] as? String ?? ""
    if owner == "AirSink" {
        print("\(id)\t\(title.isEmpty ? "main" : title)")
    }
}
SWIFT

echo
echo "Pick a window ID from above and run:"
echo "  screencapture -o -l <id> docs/screenshots/<name>.png"
