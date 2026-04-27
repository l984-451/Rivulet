//
//  FFmpegSubtitleDecoder.swift
//  Rivulet
//
//  Decodes bitmap subtitle formats (PGS, DVB-SUB) using avcodec_decode_subtitle2.
//  Converts palette-indexed bitmaps to RGBA Data for SwiftUI rendering.
//
//  PGS (Presentation Graphic Stream) subtitles are embedded bitmap subtitles
//  common in Blu-ray rips. Unlike text subtitles (SRT, ASS), they require
//  actual codec decoding to produce renderable images.
//

import Foundation

// MARK: - Decoded Subtitle Frame

/// Output of subtitle decoding: one or more positioned bitmap rects with timing.
struct DecodedSubtitleFrame: Sendable {
    let rects: [BitmapSubtitleRect]
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Codec-reported reference resolution that rect coordinates are authored
    /// against (DVDSUB sets it from extradata; PGS sets it from segment headers
    /// during decode). 0 if unknown.
    let referenceWidth: Int
    let referenceHeight: Int
}

// =============================================================================
// MARK: - FFmpeg Implementation
// =============================================================================

#if RIVULET_FFMPEG
import Libavcodec
import Libavutil

/// Decodes PGS/DVB-SUB bitmap subtitles using libavcodec.
final class FFmpegSubtitleDecoder: @unchecked Sendable {

    /// Bitmap subtitle codecs this decoder handles.
    static let supportedCodecs: Set<String> = [
        "pgs", "hdmv_pgs_subtitle", "pgssub",   // Blu-ray PGS
        "dvdsub", "dvd_subtitle",                 // DVD bitmaps
        "dvb_subtitle",                           // DVB-SUB
    ]

    static let isAvailable = true

    // MARK: - Private State

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var isOpen = false

    // MARK: - Init

    /// Open a decoder for bitmap subtitles.
    /// - Parameter codecpar: Codec parameters from the demuxer stream
    init(codecpar: UnsafePointer<AVCodecParameters>) throws {
        let codecId = codecpar.pointee.codec_id

        guard let codec = avcodec_find_decoder(codecId) else {
            let name = String(cString: avcodec_get_name(codecId))
            playerDebugLog("[SubtitleDecoder] No decoder found for codec: \(name)")
            throw FFmpegError.unsupportedCodec(name)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FFmpegError.allocationFailed
        }

        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx

        var ret = avcodec_parameters_to_context(ctx, codecpar)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        ret = avcodec_open2(ctx, codec, nil)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        self.codecContext = ctx
        self.isOpen = true

        let decoderName = String(cString: codec.pointee.name)
        playerDebugLog("[SubtitleDecoder] Opened \(decoderName) decoder")
    }

    deinit { close() }

    // MARK: - Decode

    /// Decode a bitmap subtitle packet into renderable RGBA rects.
    func decode(_ packet: DemuxedPacket) -> DecodedSubtitleFrame? {
        guard let ctx = codecContext, isOpen else { return nil }

        var avPacket = av_packet_alloc()
        guard let pkt = avPacket else { return nil }
        defer { av_packet_free(&avPacket) }

        // Fill AVPacket from DemuxedPacket data
        packet.data.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            av_new_packet(pkt, Int32(packet.data.count))
            pkt.pointee.data.update(from: baseAddress.assumingMemoryBound(to: UInt8.self),
                                     count: packet.data.count)
            pkt.pointee.pts = packet.pts
            pkt.pointee.dts = packet.dts
            pkt.pointee.duration = packet.duration
        }

        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0

        let ret = avcodec_decode_subtitle2(ctx, &subtitle, &gotSubtitle, pkt)
        guard ret >= 0, gotSubtitle != 0 else { return nil }
        defer { avsubtitle_free(&subtitle) }

        // Compute timing
        let ptsSeconds = packet.ptsSeconds
        let startDisplayMs = Double(subtitle.start_display_time) / 1000.0

        let startTime = ptsSeconds + startDisplayMs

        // PGS uses end_display_time = UInt32.max as sentinel for "until next display set".
        // Detect this and use .infinity so SubtitleManager can auto-close on next cue.
        let endTime: TimeInterval
        if subtitle.end_display_time > 0 && subtitle.end_display_time < UInt32.max - 1 {
            let endDisplayMs = Double(subtitle.end_display_time) / 1000.0
            endTime = ptsSeconds + endDisplayMs
        } else {
            let dur = Double(packet.duration) * Double(packet.timebase.value) / Double(packet.timebase.timescale)
            endTime = dur > 0 ? ptsSeconds + dur : .infinity  // Sentinel: closed by next cue
        }

        // Convert subtitle rects to RGBA bitmaps
        var rects: [BitmapSubtitleRect] = []

        let numRects = Int(subtitle.num_rects)

        if numRects > 0, let rectsPtr = subtitle.rects {
            for i in 0..<numRects {
                guard let rectPtr = rectsPtr[i] else { continue }
                let rect = rectPtr.pointee

                // Only handle bitmap types (SUBTITLE_BITMAP)
                guard rect.type == SUBTITLE_BITMAP else { continue }
                guard rect.w > 0, rect.h > 0 else { continue }

                let width = Int(rect.w)
                let height = Int(rect.h)
                let pixelCount = width * height

                // rect.data[0] = palette-indexed pixel data (1 byte per pixel)
                // rect.data[1] = RGBA palette (256 entries × 4 bytes = 1024 bytes)
                guard let indexData = rect.data.0, let paletteData = rect.data.1 else { continue }

                // Convert palette-indexed to RGBA
                var rgbaData = Data(count: pixelCount * 4)
                rgbaData.withUnsafeMutableBytes { rgbaBuf in
                    guard let rgbaPtr = rgbaBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for p in 0..<pixelCount {
                        let index = Int(indexData[p])
                        let paletteOffset = index * 4
                        rgbaPtr[p * 4 + 0] = paletteData[paletteOffset + 0] // R
                        rgbaPtr[p * 4 + 1] = paletteData[paletteOffset + 1] // G
                        rgbaPtr[p * 4 + 2] = paletteData[paletteOffset + 2] // B
                        rgbaPtr[p * 4 + 3] = paletteData[paletteOffset + 3] // A
                    }
                }

                rects.append(BitmapSubtitleRect(
                    imageData: rgbaData,
                    width: width,
                    height: height,
                    x: Int(rect.x),
                    y: Int(rect.y)
                ))
            }
        }

        // Codec reference resolution. After avcodec_decode_subtitle2, ctx.width/height
        // reflect the subtitle's authoring resolution: dvdsub_init parses "size: WxH"
        // from extradata (DVD VOBSUB → 720×480 NTSC or 720×576 PAL); pgssub reads the
        // presentation segment width/height (Blu-ray PGS → 1920×1080 even on UHD discs);
        // DVB-SUB picks up the display definition segment.
        let referenceWidth = Int(ctx.pointee.width)
        let referenceHeight = Int(ctx.pointee.height)

        // Return frame even with 0 rects — empty rects = PGS "clear screen" display set.
        // The pipeline uses this to close the previous open-ended cue.
        return DecodedSubtitleFrame(
            rects: rects,
            startTime: startTime,
            endTime: endTime,
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight
        )
    }

    // MARK: - Close

    func close() {
        guard isOpen else { return }
        isOpen = false

        if codecContext != nil {
            avcodec_free_context(&codecContext)
            codecContext = nil
        }

        playerDebugLog("[SubtitleDecoder] Closed")
    }
}

#else

// =============================================================================
// MARK: - Stub Implementation (FFmpeg not available)
// =============================================================================

/// Stub subtitle decoder when FFmpeg libraries are not linked.
final class FFmpegSubtitleDecoder: @unchecked Sendable {

    static let supportedCodecs: Set<String> = []
    static let isAvailable = false

    init(codecpar: UnsafeRawPointer) throws {
        throw FFmpegError.notAvailable
    }

    func decode(_ packet: DemuxedPacket) -> DecodedSubtitleFrame? { nil }

    func close() {}
}

#endif
