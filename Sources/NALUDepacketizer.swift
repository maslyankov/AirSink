import Foundation
import CoreMedia
import VideoToolbox

/// Turns Annex-B H.264 / H.265 access units into CMSampleBuffers for
/// AVSampleBufferDisplayLayer. Tracks parameter sets and rebuilds the
/// CMVideoFormatDescription when SPS/PPS/VPS change.
final class NALUDepacketizer {
    enum Codec: Equatable {
        case h264
        case h265
    }

    private(set) var formatDescription: CMVideoFormatDescription?
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0

    private var currentCodec: Codec?
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?  // h265 only
    private var paramsDirty = false

    func reset() {
        formatDescription = nil
        currentCodec = nil
        sps = nil
        pps = nil
        vps = nil
        paramsDirty = false
        width = 0
        height = 0
    }

    /// Parse one access unit. Returns a sample buffer if it contained a
    /// decodable picture (VCL NALUs + a valid format description).
    func process(accessUnit: Data, codec: Codec, ptsNs: UInt64) -> CMSampleBuffer? {
        if currentCodec != codec {
            reset()
            currentCodec = codec
        }

        let nalus = NALUDepacketizer.splitAnnexB(accessUnit)
        var vcl: [Data] = []

        for nalu in nalus {
            guard let header = nalu.first else { continue }
            switch codec {
            case .h264:
                let type = header & 0x1F
                switch type {
                case 7: sps = nalu; paramsDirty = true     // SPS
                case 8: pps = nalu; paramsDirty = true     // PPS
                case 1, 5: vcl.append(nalu)                // non-IDR / IDR slice
                default: break                              // SEI, AUD, etc — ignored
                }
            case .h265:
                let type = (header >> 1) & 0x3F
                switch type {
                case 32: vps = nalu; paramsDirty = true    // VPS
                case 33: sps = nalu; paramsDirty = true    // SPS
                case 34: pps = nalu; paramsDirty = true    // PPS
                case 0...9, 16...21:                        // VCL slice ranges
                    vcl.append(nalu)
                default: break
                }
            }
        }

        if paramsDirty {
            rebuildFormatDescription()
            paramsDirty = false
        }

        guard !vcl.isEmpty, let fmt = formatDescription else { return nil }
        return makeSampleBuffer(vcl: vcl, format: fmt, ptsNs: ptsNs)
    }

    // MARK: - Format description

    private func rebuildFormatDescription() {
        switch currentCodec {
        case .h264:
            guard let sps, let pps else { return }
            formatDescription = makeH264FormatDescription(sps: sps, pps: pps)
        case .h265:
            guard let vps, let sps, let pps else { return }
            formatDescription = makeH265FormatDescription(vps: vps, sps: sps, pps: pps)
        case .none:
            return
        }
        if let fmt = formatDescription {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt)
            width = dim.width
            height = dim.height
        }
    }

    private func makeH264FormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBuf -> OSStatus in
            pps.withUnsafeBytes { ppsBuf -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { ptrPtr in
                    sizes.withUnsafeBufferPointer { sizePtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrPtr.baseAddress!,
                            parameterSetSizes: sizePtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt
                        )
                    }
                }
            }
        }
        return status == noErr ? fmt : nil
    }

    private func makeH265FormatDescription(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { vpsBuf -> OSStatus in
            sps.withUnsafeBytes { spsBuf -> OSStatus in
                pps.withUnsafeBytes { ppsBuf -> OSStatus in
                    let pointers: [UnsafePointer<UInt8>] = [
                        vpsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { ptrPtr in
                        sizes.withUnsafeBufferPointer { sizePtr in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrPtr.baseAddress!,
                                parameterSetSizes: sizePtr.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &fmt
                            )
                        }
                    }
                }
            }
        }
        return status == noErr ? fmt : nil
    }

    // MARK: - Sample buffer

    private func makeSampleBuffer(vcl: [Data], format: CMVideoFormatDescription, ptsNs: UInt64) -> CMSampleBuffer? {
        // AVCC framing: [u32 BE length][NALU bytes] for each VCL NALU.
        var avccLength = 0
        for nalu in vcl { avccLength += 4 + nalu.count }

        // Hand the buffer off to CoreMedia with malloc-backed deallocator.
        guard let raw = malloc(avccLength) else { return nil }
        let dst = raw.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        for nalu in vcl {
            let len = UInt32(nalu.count).bigEndian
            _ = withUnsafeBytes(of: len) { lenBytes in
                memcpy(dst.advanced(by: offset), lenBytes.baseAddress!, 4)
            }
            offset += 4
            _ = nalu.withUnsafeBytes { src in
                memcpy(dst.advanced(by: offset), src.baseAddress!, nalu.count)
            }
            offset += nalu.count
        }

        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: raw,
            blockLength: avccLength,
            blockAllocator: kCFAllocatorMalloc,  // CoreMedia will free() it
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            free(raw)
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccLength
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

        // Live mirror: render as soon as decoded, no buffering.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                     to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sb
    }

    // MARK: - Annex-B split

    /// Split Annex-B byte stream into NALU payloads (no start codes).
    /// Accepts both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        var nalus: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 4 else { return nalus }

        // Locate every start code (position + length).
        struct StartCode { let pos: Int; let length: Int }
        var starts: [StartCode] = []
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(StartCode(pos: i, length: 3))
                    i += 3
                    continue
                } else if i + 3 < n, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append(StartCode(pos: i, length: 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        for (idx, sc) in starts.enumerated() {
            let bodyStart = sc.pos + sc.length
            let bodyEnd   = idx + 1 < starts.count ? starts[idx + 1].pos : n
            if bodyEnd > bodyStart {
                nalus.append(Data(bytes[bodyStart..<bodyEnd]))
            }
        }
        return nalus
    }
}
