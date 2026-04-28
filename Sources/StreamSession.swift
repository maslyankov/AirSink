import Foundation
import AppKit
import AVFoundation
import CoreMedia
import Combine

/// Off-main worker that owns the depacketizer + display layer and serializes
/// access on its own queue. Calls back to the session with frame dimensions.
final class StreamDecoder {
    let displayLayer: AVSampleBufferDisplayLayer

    private let depacketizer = NALUDepacketizer()
    private let queue = DispatchQueue(label: "airsink.stream.decode")

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        self.displayLayer = layer
    }

    /// Submit one access unit. `onFrame(w, h)` fires on the decode queue
    /// each time a sample buffer is enqueued; route it to main yourself.
    func process(_ frame: FrameTapClient.Frame, onFrame: @escaping (Int, Int) -> Void) {
        queue.async { [self] in
            let codec: NALUDepacketizer.Codec = (frame.codec == .h265) ? .h265 : .h264
            guard let sample = depacketizer.process(accessUnit: frame.data,
                                                    codec: codec,
                                                    ptsNs: frame.ptsNs) else { return }
            let layer = displayLayer
            if layer.status == .failed { layer.flush() }
            if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
            onFrame(Int(depacketizer.width), Int(depacketizer.height))
        }
    }

    func reset() {
        queue.async { [self] in
            depacketizer.reset()
            displayLayer.flushAndRemoveImage()
        }
    }
}

/// Front of the decode pipeline: client + decoder + UI state. SwiftUI
/// observes `state` / `frameCount`; `StreamView` installs `displayLayer`.
@MainActor
final class StreamSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting           // socket not ready / no tap client
        case connected            // tap handshake ok, no frames yet
        case streaming(width: Int, height: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var frameCount: Int = 0

    let decoder = StreamDecoder()
    var displayLayer: AVSampleBufferDisplayLayer { decoder.displayLayer }

    private let client = FrameTapClient()

    init() {
        client.onState = { [weak self] s in
            Task { @MainActor in self?.handleClientState(s) }
        }
        client.onFrame = { [weak self] frame in
            guard let self else { return }
            self.decoder.process(frame) { width, height in
                Task { @MainActor in
                    self.frameCount &+= 1
                    self.applyDimensions(width: width, height: height)
                }
            }
        }
    }

    deinit { client.disconnect() }

    func start(socketPath: String) {
        state = .connecting
        frameCount = 0
        decoder.reset()
        client.connect(to: socketPath)
    }

    func stop() {
        client.disconnect()
        decoder.reset()
        state = .idle
    }

    // MARK: - State updates

    private func handleClientState(_ s: FrameTapClient.ConnState) {
        switch s {
        case .idle:
            state = .idle
        case .connecting:
            // Don't downgrade .streaming on transient blips.
            if case .streaming = state { return }
            state = .connecting
        case .connected:
            if case .streaming = state { return }
            state = .connected
        case .failed(let msg):
            state = .failed(msg)
        }
    }

    private func applyDimensions(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if case .streaming(let cw, let ch) = state, cw == width, ch == height { return }
        state = .streaming(width: width, height: height)
    }
}
