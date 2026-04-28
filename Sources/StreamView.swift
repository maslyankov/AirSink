import SwiftUI
import AppKit
import AVFoundation

/// SwiftUI host for the session's AVSampleBufferDisplayLayer.
struct StreamView: NSViewRepresentable {
    let session: StreamSession

    func makeNSView(context: Context) -> StreamHostView {
        let view = StreamHostView()
        view.installLayer(session.displayLayer)
        return view
    }

    func updateNSView(_ nsView: StreamHostView, context: Context) {
        // The session's layer reference is stable for the life of the session,
        // so we only need to (re)install if it changed (e.g. session swap).
        if nsView.installedLayer !== session.displayLayer {
            nsView.installLayer(session.displayLayer)
        }
    }
}

/// Backing NSView that hosts a single sublayer and resizes it with the view.
final class StreamHostView: NSView {
    private(set) var installedLayer: AVSampleBufferDisplayLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { fatalError() }

    func installLayer(_ newLayer: AVSampleBufferDisplayLayer) {
        installedLayer?.removeFromSuperlayer()
        installedLayer = newLayer
        newLayer.frame = bounds
        applyContentsScale(to: newLayer)
        layer?.addSublayer(newLayer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        installedLayer?.frame = bounds
        if let l = installedLayer { applyContentsScale(to: l) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let l = installedLayer { applyContentsScale(to: l) }
    }

    private func applyContentsScale(to layer: CALayer) {
        // Without this, the layer renders at 1x and gets upscaled by the
        // compositor — soft picture and extra GPU work that shows up as judder.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        layer.rasterizationScale = scale
    }
}
